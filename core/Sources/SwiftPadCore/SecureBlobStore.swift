import Foundation

public protocol SecureBlobStore: Sendable {
    func store(key: String, bytes: Data, policy: SwiftPadCachePolicy) async throws

    func fetch(key: String, policy: SwiftPadCachePolicy) async throws -> Data?

    func evict(key: String) async throws

    func evictAll(prefix: String) async throws
}

public enum SwiftPadCachePolicy: Sendable, Equatable {
    case biometricBound

    case noBiometric
}
