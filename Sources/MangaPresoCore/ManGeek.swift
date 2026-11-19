import Foundation

/// Connects to the primary upstream and retains its original JSON payloads.
public struct ManGeekProvider: Sendable {
    private let base: URL
    private let transport: HTTPTransport
    private let clock: @Sendable () -> Date

    public init(
        base: URL = URL(string: "http://geekstations.com.br/api/v2/pt")!,
        transport: @escaping HTTPTransport = HTTP.live,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.transport = transport
        self.clock = clock
    }

    public func home() async throws -> JSON { try await fetch("home") }

    public func search(query: String = "", tag: String? = nil) async throws -> JSON {
        try await fetch("search", parameter: query, body: .object([
            "tags": .array(tag.map { [.string($0)] } ?? [])
        ]))
    }

    public func manga(id: String) async throws -> JSON {
        let result = try await fetch("manga", parameter: id)
        guard var object = result.object, let chapters = result["chapters"].array else { return result }
        // Match the reader order returned by the Python API.
        object["chapters"] = .array(Array(chapters.reversed()))
        return .object(object)
    }

    public func chapter(id: String) async throws -> JSON { try await fetch("chapter", parameter: id) }

    private func fetch(_ endpoint: String, parameter: String? = nil, body: JSON? = nil) async throws -> JSON {
        // The upstream expects an uppercase hexadecimal millisecond nonce and a signed path.
        let nonce = String(Int64(clock().timeIntervalSince1970 * 1000), radix: 16, uppercase: true)
        let signature = legacyMD5("M<\(parameter ?? nonce)#MANG33K>D")
        let path = [endpoint, nonce] + (parameter.map { [HTTP.segment($0)] } ?? []) + [signature]
        return try await HTTP.json(HTTP.request(
            base, path.joined(separator: "/"), headers: ["User-Agent": "okhttp/4.12.0"],
            body: body, timeout: 30
        ), using: transport)
    }
}

// MD5 is required by the legacy ManGeek request format.
func legacyMD5(_ string: String) -> String {
    let rotations = [[7, 12, 17, 22], [5, 9, 14, 20], [4, 11, 16, 23], [6, 10, 15, 21]]
    var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    var bytes = Array(string.utf8)
    let length = UInt64(bytes.count) * 8
    // Pad to a whole number of 64-byte blocks and append the original bit length.
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    bytes += (0..<8).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }

    // Mix each block through four rounds, then accumulate it into the digest state.
    for offset in stride(from: 0, to: bytes.count, by: 64) {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        for index in 0..<64 {
            let function: UInt32
            let word: Int
            switch index / 16 {
            case 0: (function, word) = ((b & c) | (~b & d), index)
            case 1: (function, word) = ((d & b) | (~d & c), (5 * index + 1) % 16)
            case 2: (function, word) = (b ^ c ^ d, (3 * index + 5) % 16)
            default: (function, word) = (c ^ (b | ~d), (7 * index) % 16)
            }
            let start = offset + word * 4
            let message = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[start + $1]) << ($1 * 8)) }
            let constant = UInt32(abs(sin(Double(index + 1))) * 4_294_967_296)
            let sum = a &+ function &+ constant &+ message
            let shift = rotations[index / 16][index % 4]
            (a, b, c, d) = (d, b &+ ((sum << shift) | (sum >> (32 - shift))), b, c)
        }
        state = zip(state, [a, b, c, d]).map { $0 &+ $1 }
    }
    return state.flatMap { word in
        (0..<4).map { String(format: "%02x", UInt8(truncatingIfNeeded: word >> ($0 * 8))) }
    }.joined()
}
