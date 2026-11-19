import Foundation

// Translates HTTP request targets into catalog calls and JSON responses.

/// Mount these content routes behind the host application's authentication middleware.
public struct CatalogRoutes: Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let body: JSON
    }

    private let api: CatalogAPI

    public init(api: CatalogAPI = .init()) {
        self.api = api
    }

    /// Handles an origin-form request target such as /api/search?q=one+piece.
    public func handle(method: String, target: String) async throws -> Response {
        guard let url = URLComponents(string: target), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.path.hasPrefix("/") else {
            return error(400, "Invalid request target")
        }
        let path = url.path
        let isManga = path.hasPrefix("/api/manga/") && path.count > "/api/manga/".count
        let isChapter = path.hasPrefix("/api/chapter/") && path.count > "/api/chapter/".count
        guard isManga || isChapter || ["/api/health", "/api/providers", "/api/home", "/api/search"].contains(path) else {
            return error(404, "Not Found")
        }
        guard method == "GET" else { return error(405, "Method Not Allowed") }

        // Decode form-style query strings. A literal plus arrives as %2B.
        let queryItems = URLComponents(string: "?" + (url.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
        let query = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, newest in newest })
        var includeAdult = false
        if ["/api/home", "/api/search"].contains(path), let raw = query["include_adult"] {
            switch raw.lowercased() {
            case "1", "true", "on", "yes", "y", "t": includeAdult = true
            case "0", "false", "off", "no", "n", "f": break
            default: return error(422, "Invalid include_adult value")
            }
        }
        // Map catalog outcomes to HTTP status codes and let cancellation reach the host.
        do {
            let body: JSON
            switch path {
            case "/api/health":
                body = .object(["status": .string("ok"), "message": .string("MangaPreso Backend is running")])
            case "/api/providers": body = api.providers()
            case "/api/home": body = try await api.home(includeAdult: includeAdult)
            case "/api/search": body = try await api.search(query: query["q"], tag: query["tag"], includeAdult: includeAdult)
            default:
                if isManga { body = try await api.manga(id: String(path.dropFirst("/api/manga/".count))) }
                else { body = try await api.chapter(id: String(path.dropFirst("/api/chapter/".count))) }
            }
            try Task.checkCancellation()
            return Response(status: 200, body: body)
        } catch APIError.notFound {
            return error(404, "Manga não encontrado")
        } catch {
            try Task.checkCancellation()
            return self.error(502, "Erro na API remota")
        }
    }

    private func error(_ status: Int, _ message: String) -> Response {
        Response(status: status, body: .object(["detail": .string(message)]))
    }
}
