import Foundation
import Crypto

public struct PadDocumentCache: Sendable {
    static let currentVersion: UInt8 = 0x03
    static let legacyV1Version: UInt8 = 0x01
    static let legacyV2Version: UInt8 = 0x02
    static let wireHashLength: Int = 64
    static let envelopeLength: Int = 32
    static let lengthPrefixSize: Int = 4
    static let headerSize: Int = 1 + wireHashLength + envelopeLength + lengthPrefixSize
    static let maxUserDocBytes: UInt32 = 16 * 1024 * 1024
    static let bundleHashPrefixLength: Int = 8

    let backend: SecureBlobStore
    let policy: SwiftPadCachePolicy

    public init(backend: SecureBlobStore, policy: SwiftPadCachePolicy) {
        self.backend = backend
        self.policy = policy
    }

    static func cacheKey(channel: String) -> String {
        let fullHash = ResourceHashes.expected["worker.bundle.min.js"] ?? "missing"
        let bundleHashPrefix = String(fullHash.prefix(Self.bundleHashPrefixLength))
        return "swiftpad-pad-v1-bh\(bundleHashPrefix):\(channel)"
    }

    public func evict(channel: String) async throws {
        try await backend.evict(key: Self.cacheKey(channel: channel))
    }

    func fetch(channel: String, userKey: Data) async throws -> PadCacheEntry? {
        guard Self.isPadChannelShape(channel) else { return nil }
        let key = Self.cacheKey(channel: channel)
        guard let raw = try await backend.fetch(key: key, policy: policy) else { return nil }
        guard raw.count >= Self.headerSize else { return nil }
        guard raw.first == Self.currentVersion else { return nil }

        let wireHashStart = raw.index(raw.startIndex, offsetBy: 1)
        let wireHashEnd = raw.index(wireHashStart, offsetBy: Self.wireHashLength)
        let wireHashBytes = Data(raw[wireHashStart..<wireHashEnd])
        guard let wireHash = String(data: wireHashBytes, encoding: .ascii) else { return nil }

        let envelopeStart = wireHashEnd
        let envelopeEnd = raw.index(envelopeStart, offsetBy: Self.envelopeLength)
        let storedEnvelope = Data(raw[envelopeStart..<envelopeEnd])

        let lengthStart = envelopeEnd
        let lengthEnd = raw.index(lengthStart, offsetBy: Self.lengthPrefixSize)
        var docLen: UInt32 = 0
        for byte in raw[lengthStart..<lengthEnd] {
            docLen = (docLen << 8) | UInt32(byte)
        }
        guard docLen > 0, docLen <= Self.maxUserDocBytes else { return nil }

        let docStart = lengthEnd
        guard let docEnd = raw.index(docStart, offsetBy: Int(docLen), limitedBy: raw.endIndex) else { return nil }
        let userDocBytes = Data(raw[docStart..<docEnd])

        let boundInput = Self.envelopeInput(channel: channel, anchorWireHash: wireHash, userDoc: userDocBytes)
        guard Self.verifyEnvelope(input: boundInput, userKey: userKey, storedEnvelope: storedEnvelope) else { return nil }

        guard let userDoc = String(data: userDocBytes, encoding: .utf8) else { return nil }
        return PadCacheEntry(anchorCheckpointWireHash: wireHash, userDoc: userDoc)
    }

    func store(channel: String, anchorCheckpointWireHash: String, userDoc: String, userKey: Data) async throws {
        guard Self.isPadChannelShape(channel) else {
            throw SwiftPadError.protocolError(
                "PadDocumentCache: channel must be 32 lowercase-hex chars; got '\(channel)'"
            )
        }
        guard anchorCheckpointWireHash.utf8.count == Self.wireHashLength,
              anchorCheckpointWireHash.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw SwiftPadError.protocolError(
                "PadDocumentCache: anchor wire hash must be \(Self.wireHashLength) ASCII chars; got \(anchorCheckpointWireHash.utf8.count)"
            )
        }
        let userDocData = Data(userDoc.utf8)
        guard !userDocData.isEmpty else {
            throw SwiftPadError.protocolError("PadDocumentCache: userDoc must be non-empty")
        }
        guard userDocData.count <= Int(Self.maxUserDocBytes) else {
            throw SwiftPadError.protocolError(
                "PadDocumentCache: userDoc exceeds \(Self.maxUserDocBytes)-byte cap (\(userDocData.count))"
            )
        }
        let envelope = Self.computeEnvelope(
            input: Self.envelopeInput(channel: channel, anchorWireHash: anchorCheckpointWireHash, userDoc: userDocData),
            userKey: userKey
        )
        let docLen = UInt32(userDocData.count)

        var value = Data(capacity: Self.headerSize + userDocData.count)
        value.append(Self.currentVersion)
        value.append(Data(anchorCheckpointWireHash.utf8))
        value.append(envelope)
        value.append(UInt8((docLen >> 24) & 0xFF))
        value.append(UInt8((docLen >> 16) & 0xFF))
        value.append(UInt8((docLen >> 8) & 0xFF))
        value.append(UInt8(docLen & 0xFF))
        value.append(userDocData)

        try await backend.store(key: Self.cacheKey(channel: channel), bytes: value, policy: policy)
    }

    static func envelopeInput(channel: String, anchorWireHash: String, userDoc: Data) -> Data {
        var input = Data(capacity: 1 + channel.utf8.count + anchorWireHash.utf8.count + userDoc.count)
        input.append(Self.currentVersion)
        input.append(Data(channel.utf8))
        input.append(Data(anchorWireHash.utf8))
        input.append(userDoc)
        return input
    }

    static func isPadChannelShape(_ channel: String) -> Bool {
        channel.count == 32 && channel.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func computeEnvelope(input: Data, userKey: Data) -> Data {
        if userKey.isEmpty {
            return sha256Bytes(input)
        } else {
            return hmacSha256(data: input, key: userKey)
        }
    }

    static func verifyEnvelope(input: Data, userKey: Data, storedEnvelope: Data) -> Bool {
        if userKey.isEmpty {
            return sha256Bytes(input) == storedEnvelope
        }
        let symmetricKey = SymmetricKey(data: userKey)
        return HMAC<SHA256>.isValidAuthenticationCode(
            storedEnvelope,
            authenticating: input,
            using: symmetricKey
        )
    }

    private static func sha256Bytes(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    private static func hmacSha256(data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }
}

struct PadCacheEntry: Sendable, Equatable {
    let anchorCheckpointWireHash: String
    let userDoc: String
}
