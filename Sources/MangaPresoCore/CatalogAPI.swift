import Foundation

/// Combines provider results and dispatches catalog IDs to their original sources.
/// Actor isolation protects the shared home cache across callers.
public actor CatalogAPI {
    private let manGeek: ManGeekProvider
    private let mangaFlix: MangaFlixProvider?
    private let mediocre: MediocreProvider?
    private let mangaDex: MangaDexProvider?
    private let clock = ContinuousClock()
    private var homeCache: [Bool: (expires: ContinuousClock.Instant, value: JSON)] = [:]

    public init(
        manGeek: ManGeekProvider = .init(),
        mangaFlix: MangaFlixProvider? = .init(),
        mediocre: MediocreProvider? = nil,
        mangaDex: MangaDexProvider? = .init()
    ) {
        self.manGeek = manGeek
        self.mangaFlix = mangaFlix
        self.mediocre = mediocre
        self.mangaDex = mangaDex
    }

    /// Mirrors the Python provider listing. MangaDex participates in search and ID routing.
    public nonisolated func providers() -> JSON {
        var names = ["ManGeek"]
        if mangaFlix != nil { names.append("MangaFlix") }
        if mediocre != nil { names.append("Mediocre") }
        return .object(["providers": .array(names.map(JSON.string))])
    }

    public func home(includeAdult: Bool = false) async throws -> JSON {
        if let cached = homeCache[includeAdult], cached.expires > clock.now { return cached.value }

        // Keep the primary home payload and attach sections from enabled providers.
        async let primary = manGeek.home()
        async let flix = mangaFlix?.home(includeAdult: includeAdult)
        async let md = mediocre?.home()
        guard var result = try await primary.object else { throw APIError.invalidResponse }

        if let tags = result["tags"]?.array {
            var names = Set(tags.compactMap(\.text))
            names.formUnion(["HQ", "Manhua", "Manhwa"])
            result["tags"] = .array(names.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }.map(JSON.string))
        }

        var extras: [String: JSON] = [:]
        if mangaFlix != nil { extras["mangaflix"] = (try? await flix) ?? homeSections() }
        if mediocre != nil { extras["mediocre"] = (try? await md) ?? homeSections() }
        try Task.checkCancellation()
        for (name, response) in extras {
            for section in ["trending", "tops", "news"] {
                result[name + "_" + section] = response[section]
            }
        }

        let value = JSON.object(result)
        homeCache[includeAdult] = (clock.now.advanced(by: .seconds(45)), value)
        return value
    }

    public func search(query: String? = nil, tag: String? = nil, includeAdult: Bool = false) async throws -> JSON {
        // Tag browsing uses the primary provider. Text search fans out to enabled sources.
        guard let query, !query.isEmpty else {
            guard let tag, !tag.isEmpty else { return .array([]) }
            return try await manGeek.search(tag: tag)
        }

        if mangaFlix == nil, mediocre == nil, mangaDex == nil {
            return try await manGeek.search(query: query)
        }

        async let primary = manGeek.search(query: query)
        async let flix = mangaFlix?.search(query, includeAdult: includeAdult)
        async let md = mediocre?.search(query)
        async let dex = mangaDex?.search(query)
        // Preserve source groups when an upstream search fails or returns no matches.
        let result = try? await primary
        var groups: [String: JSON] = [
            "ManGeek": .array(result?.array ?? result?["series"].array ?? [])
        ]
        if mangaFlix != nil { groups["MangaFlix"] = .array((try? await flix) ?? []) }
        if mediocre != nil { groups["Mediocre"] = .array((try? await md) ?? []) }
        if mangaDex != nil { groups["Mangadex"] = .array((try? await dex) ?? []) }
        try Task.checkCancellation()
        return .object(["grouped": .bool(true), "providers": .object(groups)])
    }

    public func manga(id: String) async throws -> JSON {
        // Strip the routing prefix before passing the provider its native ID.
        let upstreamID = String(id.dropFirst(3))
        do {
            if id.hasPrefix("mf_"), let mangaFlix { return try await mangaFlix.manga(id: upstreamID) }
            if id.hasPrefix("md_"), let mediocre { return try await mediocre.manga(id: upstreamID) }
            if id.hasPrefix("mg_"), let mangaDex { return try await mangaDex.manga(id: upstreamID) }
        } catch APIError.upstreamStatus(404) {
            throw APIError.notFound
        }
        return try await manGeek.manga(id: id)
    }

    public func chapter(id: String) async throws -> JSON {
        let upstreamID = String(id.dropFirst(3))
        if id.hasPrefix("mf_"), let mangaFlix {
            return (try? await mangaFlix.chapter(id: upstreamID)) ?? pages()
        }
        if id.hasPrefix("md_"), let mediocre {
            // Mediocre chapter IDs carry both the work ID and the native chapter ID.
            let parts = upstreamID.split(separator: "_", maxSplits: 1)
            guard parts.count == 2 else { return pages() }
            return (try? await mediocre.chapter(id: String(parts[1]), mangaID: String(parts[0]))) ?? pages()
        }
        if id.hasPrefix("mg_"), let mangaDex {
            return (try? await mangaDex.chapter(id: upstreamID)) ?? .null
        }
        return try await manGeek.chapter(id: id)
    }
}
