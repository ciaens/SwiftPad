import Foundation

actor InMemoryBlobStore: SecureBlobStore {
    private var entries: [String: Data] = [:]

    init() {}

    func store(key: String, bytes: Data, policy: SwiftPadCachePolicy) async throws {
        entries[key] = bytes
    }

    func fetch(key: String, policy: SwiftPadCachePolicy) async throws -> Data? {
        entries[key]
    }

    func evict(key: String) async throws {
        entries.removeValue(forKey: key)
    }

    func evictAll(prefix: String) async throws {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    var entryCount: Int {
        entries.count
    }
}
