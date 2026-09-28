import Foundation

struct BearerCache: Sendable {
    static let currentVersion: UInt8 = 0x01
    static let bearerLength: Int = 32
    static let valueByteCount: Int = 1 + bearerLength

    let backend: SecureBlobStore
    let policy: SwiftPadCachePolicy

    init(backend: SecureBlobStore, policy: SwiftPadCachePolicy) {
        self.backend = backend
        self.policy = policy
    }

    static func cacheKey(username: String, loginSalt: String, serverURL: URL) -> String {
        return "swiftpad-bearer-v1:\(ScryptCache.accountScope(loginSalt: loginSalt, serverURL: serverURL)):\(username.lowercased())"
    }

    static func isWellFormed(_ bearer: String) -> Bool {
        guard bearer.utf8.count == bearerLength else { return false }
        return bearer.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) ||
            (byte >= 0x30 && byte <= 0x39) || byte == 0x2b || byte == 0x2d
        }
    }

    func fetch(username: String, loginSalt: String, serverURL: URL) async throws -> String? {
        let key = Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL)
        guard let raw = try await backend.fetch(key: key, policy: policy) else { return nil }
        if raw.count == Self.valueByteCount, raw.first == Self.currentVersion,
           let bearer = String(bytes: raw.dropFirst(), encoding: .utf8), Self.isWellFormed(bearer) {
            return bearer
        }
        Trace.warn(.session, "bearer cache entry malformed (\(raw.count) bytes) — evicting")
        do {
            try await backend.evict(key: key)
        } catch {
            Trace.warn(.session, "bearer cache evict of a malformed entry failed: \(error)")
        }
        return nil
    }

    func store(username: String, loginSalt: String, serverURL: URL, bearer: String) async throws {
        guard Self.isWellFormed(bearer) else {
            throw SwiftPadError.protocolError("bearer must be \(Self.bearerLength) characters of [A-Za-z0-9+-]; got \(bearer.utf8.count) bytes")
        }
        let key = Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL)
        var value = Data(capacity: Self.valueByteCount)
        value.append(Self.currentVersion)
        value.append(contentsOf: Array(bearer.utf8))
        try await backend.store(key: key, bytes: value, policy: policy)
    }

    func evict(username: String, loginSalt: String, serverURL: URL) async throws {
        try await backend.evict(key: Self.cacheKey(username: username, loginSalt: loginSalt, serverURL: serverURL))
    }
}
