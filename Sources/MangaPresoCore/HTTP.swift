// Defines transport injection, JSON values, and the shared provider payload builders.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The upstream providers use different JSON schemas and both string and integer IDs.
public enum JSON: Codable, Sendable, Equatable {
    case object([String: JSON]), array([JSON]), string(String)
    case integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([JSON].self) { self = .array(result) }
        else { self = .object(try value.decode([String: JSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSON { object?[key] ?? .null }
    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
    public var text: String? {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        default: nil
        }
    }

    func firstText(_ keys: String...) -> String {
        keys.lazy.compactMap { self[$0].text }.first { !$0.isEmpty } ?? ""
    }
}

public enum APIError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case upstreamStatus(Int)
    case notFound
    case authenticationFailed
}

/// Supply a custom transport to control HTTP behavior or return offline fixtures.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTP {
    public static let live: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, response)
    }

    // Encode a provider ID as one path segment before building the request.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )) ?? ""
    }

    static func request(
        _ base: URL, _ path: String, query: [String: String] = [:],
        headers: [String: String] = [:], body: JSON? = nil, timeout: Double = 15
    ) throws -> URLRequest {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        let basePath = components.percentEncodedPath
        components.percentEncodedPath = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath) + "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("okhttp/4.11.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    static func json(_ request: URLRequest, using transport: HTTPTransport) async throws -> JSON {
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.upstreamStatus(response.statusCode)
        }
        // Providers can use 204 to signal an absent or empty payload.
        if response.statusCode == 204 { return .null }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}

// Map provider-specific fields to the catalog keys used by the existing reader.
func catalogItem(
    id: String, title: JSON, description: JSON, thumbnail: String,
    source: String, tags: [JSON]? = nil, chapters: [JSON]? = nil
) -> JSON {
    var item: [String: JSON] = [
        "id": .string(id), "title": title, "description": description,
        "thumbnail": .string(thumbnail), "source": .string(source)
    ]
    if let tags { item["tags"] = .array(tags) }
    if let chapters { item["chapters"] = .array(chapters) }
    return .object(item)
}

func chapterItem(id: String, title: String, date: JSON) -> JSON {
    .object(["id": .string(id), "title": .string(title), "date": date])
}

func pages(_ urls: [String] = []) -> JSON {
    .object(["pages": .array(urls.map(JSON.string))])
}
