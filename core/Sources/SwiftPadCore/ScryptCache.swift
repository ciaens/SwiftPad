import Foundation
import Crypto

struct ScryptCache: Sendable {
    static let currentVersion: UInt8 = 0x01
    static let scryptOutputBytes: Int = 192
    static let valueByteCount: Int = 1 + scryptOutputBytes

    let backend: SecureBlobStore
    let policy: SwiftPadCachePolicy

    init(backend: SecureBlobStore, policy: SwiftPadCachePolicy) {
        self.backend = backend
        self.policy = policy
    }

    static func cacheKey(username: String, loginSalt: String, serverURL: URL) -> String {
        return "swiftpad-scrypt-v1:\(accountScope(loginSalt: loginSalt, serverURL: serverURL)):\(username.lowercased())"
    }

    static func accountScope(loginSalt: String, serverURL: URL) -> String {
        let host = (serverURL.host ?? serverURL.absoluteString).lowercased()
        let port = serverURL.port.map { ":\($0)" } ?? ""
        let scheme = (serverURL.scheme ?? "").lowercased()
        let serverComponent = "\(scheme)://\(host)\(port)"
        return sha256Hex("\(loginSalt)|\(serverComponent)")
    }

    func fetch(username: String, loginSalt: String, serverURL: URL) async throws -> Data? {
        let key = Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL)
        guard let raw = try await backend.fetch(key: key, policy: policy) else { return nil }
        guard raw.count == Self.valueByteCount, raw.first == Self.currentVersion else {
            return nil
        }
        return Data(raw.dropFirst())
    }

    func store(username: String, loginSalt: String, serverURL: URL, scryptBytes: Data) async throws {
        guard scryptBytes.count == Self.scryptOutputBytes else {
            throw SwiftPadError.protocolError("scrypt output must be \(Self.scryptOutputBytes) bytes; got \(scryptBytes.count)")
        }
        let key = Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL)
        var value = Data(capacity: Self.valueByteCount)
        value.append(Self.currentVersion)
        value.append(scryptBytes)
        try await backend.store(key: key, bytes: value, policy: policy)
    }

    func evict(username: String, loginSalt: String, serverURL: URL) async throws {
        try await backend.evict(key: Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL))
    }

    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
