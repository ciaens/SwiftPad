import Foundation
import Crypto

public struct DriveSnapshotCache: Sendable {
    static let currentVersion: UInt8 = 0x02
    static let legacyV1Version: UInt8 = 0x01
    static let envelopeLength: Int = 32
    static let lengthPrefixSize: Int = 4
    static let headerSize: Int = 1 + envelopeLength + lengthPrefixSize
    static let maxUserDocBytes: UInt32 = 16 * 1024 * 1024
    static let bundleHashPrefixLength: Int = 8

    let backend: SecureBlobStore
    let policy: SwiftPadCachePolicy

    public init(backend: SecureBlobStore, policy: SwiftPadCachePolicy) {
        self.backend = backend
        self.policy = policy
    }

    static func cacheKey(username: String, serverURL: URL, teamId: String? = nil) -> String {
        let fullHash = ResourceHashes.expected["worker.bundle.min.js"] ?? "missing"
        let bundleHashPrefix = String(fullHash.prefix(Self.bundleHashPrefixLength))
        let identityInput = username.lowercased() + "\u{0000}" + serverURL.absoluteString
            + "\u{0000}" + (teamId ?? "")
        let identityHash = sha256Hex(Data(identityInput.utf8))
        return "swiftpad-drive-v2-bh\(bundleHashPrefix):\(identityHash)"
    }

    public func fetchSnapshot(username: String, serverURL: URL, userKey: Data, teamId: String? = nil) async throws -> DriveSnapshotEntry? {
        let key = Self.cacheKey(username: username, serverURL: serverURL, teamId: teamId)
        guard let raw = try await backend.fetch(key: key, policy: policy) else { return nil }
        guard raw.count >= Self.headerSize else { return nil }
        guard raw.first == Self.currentVersion else { return nil }

        let envelopeStart = raw.index(raw.startIndex, offsetBy: 1)
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

        guard Self.verifyEnvelope(userDoc: userDocBytes, userKey: userKey, storedEnvelope: storedEnvelope) else { return nil }

        guard let driveUserDoc = String(data: userDocBytes, encoding: .utf8) else { return nil }
        return DriveSnapshotEntry(driveUserDoc: driveUserDoc)
    }

    public func storeSnapshot(username: String, serverURL: URL, driveUserDoc: String, userKey: Data, teamId: String? = nil) async throws {
        let userDocData = Data(driveUserDoc.utf8)
        guard !userDocData.isEmpty else {
            throw SwiftPadError.protocolError("DriveSnapshotCache: driveUserDoc must be non-empty")
        }
        guard userDocData.count <= Int(Self.maxUserDocBytes) else {
            throw SwiftPadError.protocolError(
                "DriveSnapshotCache: driveUserDoc exceeds \(Self.maxUserDocBytes)-byte cap (\(userDocData.count))"
            )
        }
        let envelope = Self.computeEnvelope(userDoc: userDocData, userKey: userKey)
        let docLen = UInt32(userDocData.count)

        var value = Data(capacity: Self.headerSize + userDocData.count)
        value.append(Self.currentVersion)
        value.append(envelope)
        value.append(UInt8((docLen >> 24) & 0xFF))
        value.append(UInt8((docLen >> 16) & 0xFF))
        value.append(UInt8((docLen >> 8) & 0xFF))
        value.append(UInt8(docLen & 0xFF))
        value.append(userDocData)

        try await backend.store(
            key: Self.cacheKey(username: username, serverURL: serverURL, teamId: teamId),
            bytes: value,
            policy: policy
        )
    }

    public func evict(username: String, serverURL: URL, teamId: String? = nil) async throws {
        try await backend.evict(key: Self.cacheKey(username: username, serverURL: serverURL, teamId: teamId))
    }

    static func computeEnvelope(userDoc: Data, userKey: Data) -> Data {
        if userKey.isEmpty {
            return sha256Bytes(userDoc)
        } else {
            return hmacSha256(data: userDoc, key: userKey)
        }
    }

    static func verifyEnvelope(userDoc: Data, userKey: Data, storedEnvelope: Data) -> Bool {
        if userKey.isEmpty {
            return sha256Bytes(userDoc) == storedEnvelope
        }
        let symmetricKey = SymmetricKey(data: userKey)
        return HMAC<SHA256>.isValidAuthenticationCode(
            storedEnvelope,
            authenticating: userDoc,
            using: symmetricKey
        )
    }

    private static func sha256Bytes(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSha256(data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }
}

public struct DriveSnapshotEntry: Sendable, Equatable {
    public let driveUserDoc: String
}
