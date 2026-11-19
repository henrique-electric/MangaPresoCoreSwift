import Foundation

/// Loads MangaDex search results, Portuguese chapter feeds, covers, and page URLs.
public struct MangaDexProvider: Sendable {
    private let base: URL
    private let uploads: URL
    private let transport: HTTPTransport

    public init(
        base: URL = URL(string: "https://api.mangadex.org")!,
        uploads: URL = URL(string: "https://uploads.mangadex.org")!,
        transport: @escaping HTTPTransport = HTTP.live
    ) {
        self.base = base
        self.uploads = uploads
        self.transport = transport
    }

    public func search(_ query: String) async throws -> [JSON] {
        let response = try await fetch("manga", ["title": query])
        let items = (response["data"].array ?? []).filter {
            $0["attributes"]["availableTranslatedLanguages"].array?.contains(.string("pt-br")) == true
        }
        // Resolve covers concurrently and restore the upstream result order by index.
        return await withTaskGroup(of: (Int, JSON).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await normalize(item)) }
            }
            var results: [(Int, JSON)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    public func manga(id: String) async throws -> JSON {
        let path = "manga/\(HTTP.segment(id))"
        // Fetch metadata and chapter feed together, then keep pt-br chapters.
        async let details = fetch(path)
        async let feed = fetch(path + "/feed")
        let data = try await details["data"]
        guard data["id"].text != nil else { throw APIError.notFound }
        let chapters = (try await feed["data"].array ?? []).compactMap { item -> JSON? in
            let attributes = item["attributes"]
            guard attributes["translatedLanguage"].text == "pt-br", let id = item["id"].text else { return nil }
            return chapterItem(
                id: "mg_" + id, title: "Capítulo " + (attributes["chapter"].text ?? "None"),
                date: attributes["publishAt"]
            )
        }
        return await normalize(data, chapters: chapters)
    }

    public func chapter(id: String) async throws -> JSON {
        let result = try await fetch("at-home/server/\(HTTP.segment(id))")
        // Combine the chapter hash and ordered filenames into reader page URLs.
        let chapter = result["chapter"]
        guard let hash = chapter["hash"].text else { throw APIError.invalidResponse }
        return pages((chapter["data"].array ?? []).compactMap { file in
            file.text.flatMap {
                try? HTTP.request(uploads, "data/\(HTTP.segment(hash))/\(HTTP.segment($0))").url?.absoluteString
            }
        })
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> JSON {
        try await HTTP.json(HTTP.request(base, path, query: query), using: transport)
    }

    private func normalize(_ item: JSON, chapters: [JSON]? = nil) async -> JSON {
        let attributes = item["attributes"]
        let id = item.firstText("id")
        let title = attributes["title"].firstText("ja-ro", "en")
        // The cover relationship points to a separate record containing its filename.
        var thumbnail = ""
        if let cover = item["relationships"].array?.first(where: { $0["type"].text == "cover_art" }),
           let coverID = cover["id"].text,
           let result = try? await fetch("cover/\(HTTP.segment(coverID))"),
           let file = result["data"]["attributes"]["fileName"].text {
            thumbnail = (try? HTTP.request(uploads, "covers/\(HTTP.segment(id))/\(HTTP.segment(file))").url?.absoluteString) ?? ""
        }
        return catalogItem(
            id: "mg_" + id, title: title.isEmpty ? .null : .string(title),
            description: chapters == nil ? attributes["description"] : attributes["description"]["pt-br"],
            thumbnail: thumbnail, source: "Mangadex", chapters: chapters
        )
    }
}
