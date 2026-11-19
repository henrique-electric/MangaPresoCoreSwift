// Exercises the exported catalog and route adapter with offline provider fixtures.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MangaPresoCore

// Build a transport response without starting an HTTP listener.
private func reply(_ request: URLRequest, _ body: String, status: Int = 200) throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (Data(body.utf8), response)
}

// Check the legacy signing format and form-style decoding for tag searches.
@Test func legacySignatureAndTagSearch() async throws {
    #expect(legacyMD5("") == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(legacyMD5("abc") == "900150983cd24fb0d6963f7d28e17f72")
    let manGeek = ManGeekProvider(transport: { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/search/1//" + legacyMD5("M<#MANG33K>D")) == true)
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(JSON.self, from: body)["tags"] == .array([.string("Ficção científica")]))
        return try reply(request, #"[{"id":123}]"#)
    }, clock: { Date(timeIntervalSince1970: 0.001) })
    let routes = CatalogRoutes(api: CatalogAPI(manGeek: manGeek))
    let response = try await routes.handle(method: "GET", target: "/api/search?tag=Fic%C3%A7%C3%A3o+cient%C3%ADfica")
    #expect(response.status == 200)
    #expect(response.body.array?.first?["id"] == .integer(123))
}

// Check mixed-source results, language filtering, and prefix-based chapter routing.
@Test func groupedSearchAndProviderChapterRouting() async throws {
    let transport: HTTPTransport = { request in
        switch request.url?.path {
        case let path? where path.contains("/api/v2/pt/search/"):
            return try reply(request, #"{"series":[{"id":123}]}"#)
        case "/v1/search/mangas":
            #expect(request.url?.absoluteString.contains("query=A%2BB") == true)
            #expect(request.url?.absoluteString.contains("include_adult=true") == true)
            return try reply(request, #"{"data":{"works":[{"_id":"flix","name":"Flix"}]}}"#)
        case "/manga":
            return try reply(request, """
            {"data":[{"id":"dex","attributes":{"title":{"en":"Dex"},"availableTranslatedLanguages":["pt-br"]}},
            {"id":"filtered","attributes":{"availableTranslatedLanguages":["en"]}}]}
            """)
        case "/v1/chapters/one":
            return try reply(request, #"{"data":{"images":[{"order":2,"default_url":"b"},{"order":1,"default_url":"a"}]}}"#)
        case "/at-home/server/two":
            return try reply(request, #"{"chapter":{"hash":"hash","data":["page.webp"]}}"#)
        default:
            Issue.record("Unexpected request \(String(describing: request.url))")
            return try reply(request, "{}", status: 404)
        }
    }
    let routes = CatalogRoutes(api: CatalogAPI(
        manGeek: .init(transport: transport), mangaFlix: .init(transport: transport),
        mangaDex: .init(transport: transport)
    ))
    let response = try await routes.handle(method: "GET", target: "/api/search?q=A%2BB&include_adult=true")
    #expect(response.status == 200)
    let results = response.body["providers"]
    #expect(results["ManGeek"].array?.first?["id"] == .integer(123))
    #expect(results["MangaFlix"].array?.first?["id"] == .string("mf_flix"))
    #expect(results["Mangadex"].array?.map { $0["id"] } == [.string("mg_dex")])

    let flix = try await routes.handle(method: "GET", target: "/api/chapter/mf_one")
    #expect(flix.body["pages"] == .array([.string("a"), .string("b")]))
    let dex = try await routes.handle(method: "GET", target: "/api/chapter/mg_two")
    #expect(dex.body["pages"] == .array([.string("https://uploads.mangadex.org/data/hash/page.webp")]))
}

// Simulate an expired token and a missing CDN manifest in the same chapter request.
@Test func mediocreRenewsTokenAndFallsBackToEmbeddedPages() async throws {
    let provider = MediocreProvider(
        credentials: .init(email: "reader@example.test", password: "example"),
        accessToken: "previous",
        transport: { request in
            switch request.url?.path {
            case "/auth/login":
                let body = try #require(request.httpBody)
                #expect(try JSONDecoder().decode(JSON.self, from: body)["senha"] == .string("example"))
                return try reply(request, #"{"data":{"token":"fresh"}}"#, status: 201)
            case "/capitulos/cap_id":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer previous" {
                    return try reply(request, "{}", status: 401)
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
                return try reply(request, #"{"cap_uuid":"uuid","cap_num":"2,0","paginas2":[{"src":"page.webp"}]}"#)
            case "/obras/17/capitulos/2/uuid.json":
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return try reply(request, "{}", status: 404)
            default:
                Issue.record("Unexpected request \(String(describing: request.url))")
                return try reply(request, "{}", status: 404)
            }
        }
    )
    let api = CatalogAPI(mediocre: provider)
    let result = try await api.chapter(id: "md_17_cap_id")
    #expect(result["pages"] == .array([.string("https://cdn.mediocrescan.com/obras/17/capitulos/2/page.webp")]))
}

// Check the combined home payload and the chapter order expected by the reader.
@Test func homeSectionsAndPrimaryChapterOrder() async throws {
    let transport: HTTPTransport = { request in
        switch request.url?.path {
        case let path? where path.contains("/api/v2/pt/home/"):
            return try reply(request, #"{"tags":["Manga","HQ","Manga"],"tops":[{"id":12}]}"#)
        case let path? where path.contains("/api/v2/pt/manga/"):
            return try reply(request, #"{"chapters":[{"id":1},{"id":2}]}"#)
        case "/v1/browse":
            return try reply(request, #"{"data":[{"key":"most-read","items":[{"_id":"top"}]}]}"#)
        case "/v1/latest-releases":
            return try reply(request, #"{"data":[{"_id":"latest"}]}"#)
        default:
            Issue.record("Unexpected request \(String(describing: request.url))")
            return try reply(request, "{}", status: 404)
        }
    }
    let routes = CatalogRoutes(api: CatalogAPI(
        manGeek: .init(transport: transport), mangaFlix: .init(transport: transport)
    ))
    let home = try await routes.handle(method: "GET", target: "/api/home")
    #expect(home.status == 200)
    #expect(home.body["tags"].array?.compactMap(\.text) == ["HQ", "Manga", "Manhua", "Manhwa"])
    #expect(home.body["tops"].array?.first?["id"] == .integer(12))
    #expect(home.body["mangaflix_tops"].array?.first?["id"] == .string("mf_top"))
    #expect(home.body["mangaflix_news"].array?.first?["id"] == .string("mf_latest"))

    let manga = try await routes.handle(method: "GET", target: "/api/manga/12")
    #expect(manga.status == 200)
    #expect(manga.body["chapters"].array?.map { $0["id"] } == [.integer(2), .integer(1)])
}
