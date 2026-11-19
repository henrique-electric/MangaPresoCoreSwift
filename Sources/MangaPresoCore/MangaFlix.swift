import Foundation

/// Loads Portuguese MangaFlix catalog data and normalizes it for the reader.
public struct MangaFlixProvider: Sendable {
    private let base: URL
    private let transport: HTTPTransport

    public init(
        base: URL = URL(string: "https://api.mangaflix.net/v1")!,
        transport: @escaping HTTPTransport = HTTP.live
    ) {
        self.base = base
        self.transport = transport
    }

    public func home(includeAdult: Bool = false) async throws -> JSON {
        let query = ["include_adult": String(includeAdult)]
        // Fetch curated sections and recent releases concurrently.
        async let browse = fetch("browse", query)
        async let latest = fetch("latest-releases", query)
        var trending: [JSON] = []
        var tops: [JSON] = []
        for section in try await browse.array ?? [] {
            let items = (section["items"].array ?? []).prefix(12).map { normalize($0) }
            if section["key"].text == "most-read" { tops = items }
            else { trending.append(contentsOf: items) }
        }
        let news = (try await latest.array ?? []).prefix(12).map { normalize($0) }
        return homeSections(trending: Array(trending.prefix(12)), tops: tops, news: news)
    }

    public func search(_ query: String, includeAdult: Bool = false) async throws -> [JSON] {
        let data = try await fetch("search/mangas", [
            "query": query, "include_adult": String(includeAdult), "multi": "true"
        ])
        return (data["works"].array ?? []).map { normalize($0) }
    }

    public func manga(id: String) async throws -> JSON {
        let data = try await fetch("mangas/\(HTTP.segment(id))")
        guard data["_id"].text != nil else { throw APIError.notFound }
        let chapters = (data["chapters"].array ?? []).map { chapter in
            chapterItem(
                id: "mf_" + chapter.firstText("_id"),
                title: "Capítulo " + (chapter["number"].text ?? "?"),
                date: chapter.object?["date"] ?? .string("")
            )
        }
        return normalize(data, chapters: chapters)
    }

    public func chapter(id: String) async throws -> JSON {
        let result = try await fetch("chapters/\(HTTP.segment(id))")
        // Image records carry an explicit reading order.
        let images = (result["images"].array ?? []).sorted {
            (Double($0.firstText("order")) ?? 0) < (Double($1.firstText("order")) ?? 0)
        }
        return pages(images.compactMap { $0["default_url"].text }.filter { !$0.isEmpty })
    }

    public func genres(includeAdult: Bool = false) async throws -> [String] {
        let result = try await fetch("genres", ["include_adult": String(includeAdult)])
        return (result.array ?? []).compactMap { $0["name"].text }.filter { !$0.isEmpty }
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> JSON {
        var parameters = query
        // Every MangaFlix operation asks the upstream for Brazilian Portuguese.
        parameters["selected_language"] = "pt-BR"
        return try await HTTP.json(HTTP.request(base, path, query: parameters), using: transport)["data"]
    }

    // List and detail entries share the same fields. Detail entries add chapters.
    private func normalize(_ item: JSON, chapters: [JSON]? = nil) -> JSON {
        let tags = (item["genres"].array ?? []).compactMap { value -> JSON? in
            if case .string = value { return value }
            return value.object.map { $0["name"] ?? .string("") }
        }
        return catalogItem(
            id: "mf_" + item.firstText("_id"), title: item.object?["name"] ?? .string(""),
            description: item.object?["description"] ?? .string(""),
            thumbnail: item["poster"].firstText("default_url"), source: "MangaFlix",
            tags: tags, chapters: chapters
        )
    }
}

func homeSections(trending: [JSON] = [], tops: [JSON] = [], news: [JSON] = []) -> JSON {
    .object(["trending": .array(trending), "tops": .array(tops), "news": .array(news)])
}
