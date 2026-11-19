import Foundation

/// Loads Mediocre catalog and reader data while coordinating an in-memory upstream session.
public actor MediocreProvider {
    private let base: URL
    private let cdn: URL
    private let transport: HTTPTransport
    private let credentials: Credentials?
    private var token: String?
    private var login: Task<String, any Error>?
    private var nextLogin = Date.distantPast

    private static let headers = [
        "Accept": "*/*",
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Linux; Android 15; Galaxy S24 Build/AP3A.241105.008; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 Mobile Safari/537.36"
    ]

    public struct Credentials: Sendable {
        public let email: String
        public let password: String

        public init(email: String, password: String) {
            self.email = email
            self.password = password
        }
    }

    public init(
        base: URL = URL(string: "https://back2.mediocrescan.com")!,
        cdn: URL = URL(string: "https://cdn.mediocrescan.com")!,
        credentials: Credentials? = nil,
        accessToken: String? = nil,
        transport: @escaping HTTPTransport = HTTP.live
    ) {
        self.base = base
        self.cdn = cdn
        self.credentials = credentials
        self.token = accessToken
        self.transport = transport
    }

    public func search(_ query: String) async throws -> [JSON] {
        let result = try await fetch("obras/buscar", [
            "string": query, "formato": "1,3,4,5,13", "limite": "24",
            "pagina": "1", "temCapitulo": "true", "ordenarPor": "criada_em_desc"
        ])
        return unwrap(result).map { normalize($0) }
    }

    public func home() async throws -> JSON {
        async let recent = fetch("obras/adicionados-recentes", ["limit": "24", "offset": "0", "formato": "5"])
        let result = try await fetch("obras/home", ["formato": "5", "limit": "12"])
        guard result != .null else { return homeSections() }
        let news = (try? await recent) ?? .null
        return homeSections(
            trending: unwrap(result).prefix(12).map { normalize($0) },
            news: unwrap(news).prefix(12).map { normalize($0) }
        )
    }

    public func manga(id: String) async throws -> JSON {
        let data = try await fetch("obras/\(HTTP.segment(id))")
        let obra = data.firstText("id", "obr_id")
        guard !obra.isEmpty else { throw APIError.notFound }
        let chapters = (data["capitulos"].array ?? []).map { item in
            let name = item.firstText("nome", "cap_nome", "numero", "cap_num")
            return chapterItem(
                id: "md_\(obra)_\(item.firstText("id", "cap_id"))",
                title: name.contains("Capítulo") ? name : "Capítulo " + name,
                date: .string(item.firstText("lancado_em", "cap_lancado_em", "criado_em", "cap_criado_em"))
            )
        }
        return normalize(data, chapters: chapters)
    }

    public func chapter(id: String, mangaID: String? = nil) async throws -> JSON {
        let data = try await fetch("capitulos/\(HTTP.segment(id))")
        let nestedID = data["obra"].firstText("id", "obr_id")
        let obra = mangaID ?? (nestedID.isEmpty ? data.firstText("obr_id") : nestedID)
        let uuid = data.firstText("cap_uuid", "uuid")
        let rawNumber = data.firstText("cap_num", "numero")
        // The CDN uses a normalized chapter number in manifest and image paths.
        let decimal = rawNumber.replacingOccurrences(of: ",", with: ".")
        let number = Double(decimal).map { Int64(exactly: $0).map(String.init) ?? String($0) } ?? rawNumber
        let directory = "obras/\(HTTP.segment(obra))/capitulos/\(HTTP.segment(number))"
        // Prefer the CDN manifest and fall back to pages embedded in the chapter response.
        var items: [JSON] = []
        if !obra.isEmpty, !uuid.isEmpty, !number.isEmpty,
           let request = try? HTTP.request(cdn, directory + "/" + HTTP.segment(uuid) + ".json", headers: Self.headers, timeout: 10),
           let manifest = try? await HTTP.json(request, using: transport) {
            items = manifest.array ?? []
        }
        if items.isEmpty {
            items = data["paginas2"].array ?? []
            if items.isEmpty { items = data["paginas"].array ?? [] }
        }
        return pages(items.compactMap { item in
            let path = (item.text ?? item.firstText("url", "src", "imagem")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            let relative = path.drop(while: { $0 == "/" }).split(separator: "/").map { HTTP.segment(String($0)) }.joined(separator: "/")
            return try? HTTP.request(cdn, path.contains("obras/") ? relative : directory + "/" + relative).url?.absoluteString
        })
    }

    private func unwrap(_ json: JSON) -> [JSON] { json.array ?? json["data"].array ?? json["items"].array ?? [] }

    // Handle the current and legacy field names while producing the shared catalog shape.
    private func normalize(_ item: JSON, chapters: [JSON]? = nil) -> JSON {
        let id = item.firstText("id", "obr_id")
        let image = item.firstText("imagem", "obr_imagem").drop(while: { $0 == "/" })
        let thumbnail = image.isEmpty ? "" : (try? HTTP.request(
            base, "media/obras/\(HTTP.segment(id))/capa",
            query: ["f": String(image), "q": "40", "fit": "cover", "w": "600"]
        ).url?.absoluteString) ?? ""
        let tags = (item["tags"].array ?? item["obr_tags"].array ?? []).compactMap { tag -> JSON? in
            if case .string = tag { return tag }
            return tag.object.map { _ in .string(tag.firstText("nome", "tag_nome")) }
        }
        return catalogItem(
            id: "md_" + id, title: .string(item.firstText("nome", "obr_nome")),
            description: .string(item.firstText("descricao", "obr_descricao")),
            thumbnail: thumbnail, source: "Mediocre", tags: tags, chapters: chapters
        )
    }

    private func fetch(_ path: String, _ query: [String: String]) async throws -> JSON {
        if token == nil, credentials != nil { _ = try await authenticate() }
        // On a 401, reuse a token refreshed by another request or sign in and retry once.
        let previousToken = token
        do {
            return try await request(path, query, token: previousToken)
        } catch APIError.upstreamStatus(401) where credentials != nil {
            let retryToken: String
            if let token, token != previousToken { retryToken = token }
            else { retryToken = try await authenticate() }
            return try await request(path, query, token: retryToken)
        }
    }

    private func fetch(_ path: String) async throws -> JSON { try await fetch(path, [:]) }

    private func request(_ path: String, _ query: [String: String], token: String?) async throws -> JSON {
        var headers = Self.headers
        if let token { headers["Authorization"] = "Bearer " + token }
        return try await HTTP.json(HTTP.request(base, path, query: query, headers: headers), using: transport)
    }

    private func authenticate() async throws -> String {
        // Share an in-flight login and limit repeated attempts after a failure.
        if let login { return try await login.value }
        guard let credentials, Date() >= nextLogin else { throw APIError.authenticationFailed }
        let login = Task { [base, transport] in
            let result = try await HTTP.json(HTTP.request(base, "auth/login", headers: Self.headers, body: .object([
                "email": .string(credentials.email), "senha": .string(credentials.password)
            ])), using: transport)
            let data = result["data"].object == nil ? result : result["data"]
            let token = data.firstText("token", "access_token")
            guard !token.isEmpty else { throw APIError.authenticationFailed }
            return token
        }
        self.login = login
        defer { self.login = nil }
        do {
            let value = try await login.value
            token = value
            return value
        } catch {
            nextLogin = Date().addingTimeInterval(60)
            throw error
        }
    }
}
