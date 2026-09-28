import Foundation

public struct DriveEntry: Sendable, Decodable {
    public let id: String
    public let title: String
    public let href: String
    public let channel: String
    public let atime: Double
    public let ctime: Double
    public let owners: [String]?
    public let password: String?

    public static let maxOwnerBytes = 128

    enum CodingKeys: String, CodingKey {
        case id, title, href, channel, atime, ctime, owners, password
    }

    init(id: String, title: String, href: String, channel: String,
         atime: Double, ctime: Double, owners: [String]?, password: String? = nil) {
        self.id = id
        self.title = title
        self.href = href
        self.channel = channel
        self.atime = atime
        self.ctime = ctime
        self.owners = owners
        self.password = password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id      = try c.decode(String.self, forKey: .id)
        self.title   = try c.decode(String.self, forKey: .title)
        self.href    = try c.decode(String.self, forKey: .href)
        self.channel = try c.decode(String.self, forKey: .channel)
        self.atime   = try c.decode(Double.self, forKey: .atime)
        self.ctime   = try c.decode(Double.self, forKey: .ctime)
        if let raw = try c.decodeIfPresent([String].self, forKey: .owners) {
            for owner in raw where owner.utf8.count > Self.maxOwnerBytes {
                throw DecodingError.dataCorruptedError(
                    forKey: .owners, in: c,
                    debugDescription: "owner string exceeds \(Self.maxOwnerBytes)-byte cap (got \(owner.utf8.count))")
            }
            self.owners = raw
        } else {
            self.owners = nil
        }
        self.password = try c.decodeIfPresent(String.self, forKey: .password)
    }
}

public struct PadMetadata: Sendable {
    public let channel: String
    public let metadata: String
}

public struct PadContent: Sendable, Equatable {
    public let channel: String

    public let type: String

    public let raw: String

    public let decoded: Decoded

    public enum Decoded: Sendable, Equatable {
        case pad
        case code(CodePadContent)
        case slide(SlidePadContent)
        case unknown
    }
}

public struct CodePadContent: Sendable, Equatable {
    public let content: String

    public let highlightMode: String

    public let authormarks: String?

    public let metadata: String?
}

public struct SlidePadContent: Sendable, Equatable {
    public let content: String

    public let metadata: String?
}

public struct CreatedPad: Sendable, Decodable {
    public let href: String
    public let title: String
    public let type: String
    public let channel: String
}

public struct FileBlobMetadata: Sendable, Equatable {
    public let name: String

    public let mimeType: String

    public let driveTitle: String

    public init(name: String, mimeType: String, driveTitle: String) {
        self.name = name
        self.mimeType = mimeType
        self.driveTitle = driveTitle
    }
}

public struct FileBlobStream: Sendable {
    public let channel: String

    public let metadata: FileBlobMetadata

    public let chunks: AsyncThrowingStream<Data, Error>

    public init(channel: String, metadata: FileBlobMetadata, chunks: AsyncThrowingStream<Data, Error>) {
        self.channel = channel
        self.metadata = metadata
        self.chunks = chunks
    }
}

public struct FileUploadProgress: Sendable, Equatable {
    public let bytesUploaded: Int
    public let bytesEstimate: Int

    public init(bytesUploaded: Int, bytesEstimate: Int) {
        self.bytesUploaded = bytesUploaded
        self.bytesEstimate = bytesEstimate
    }
}

public struct DriveTree: Sendable, Decodable {
    public let root: DriveFolder
    public let trash: [DriveTrashName]
    public let templates: [DriveEntry]
    public let filesData: [DriveEntry]

    enum CodingKeys: String, CodingKey {
        case root, trash, filesData
        case templates = "template"
    }
}

public struct DriveFolder: Sendable, Decodable {
    public let name: String
    public let entries: [DriveEntry]
    public let folders: [DriveFolder]
}

public struct DriveTrashName: Sendable, Decodable {
    public let name: String
    public let entries: [DriveEntry]
}

public struct PinnedUsage: Sendable, Decodable {
    public let bytes: Int64
}

public struct PinLimit: Sendable, Decodable {
    public let limit: Int64
    public let plan: String
    public let note: String
}

public struct ShareLinks: Sendable, Decodable, Equatable {
    public let edit: String?
    public let view: String
    public let present: String
    public let embed: String
}

public struct AccountInfo: Sendable, Decodable, Equatable {
    public let edPublic: String
    public let curvePublic: String
    public let profileUrl: String?
    public let notifications: String?
}

public struct UserProfile: Sendable, Decodable, Equatable {
    public let name: String?
    public let description: String?
    public let url: String?
    public let avatar: String?
    public let edPublic: String?
    public let curvePublic: String?
    public let proof: String?
    public let channel: String?
}


public struct TeamSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let owner: Bool
    public let offline: Bool
    public let error: Bool
    public let driveEdPublic: String?
}

public enum TeamRole: Sendable, Equatable, Codable {
    case owner, admin, member, viewer
    case unknown(String)

    init(wireString: String?) {
        guard let raw = wireString, !raw.isEmpty else { self = .viewer; return }
        switch raw.uppercased() {
        case "OWNER": self = .owner
        case "ADMIN": self = .admin
        case "MEMBER": self = .member
        case "VIEWER": self = .viewer
        default: self = .unknown(raw)
        }
    }

    public var wireValue: String {
        switch self {
        case .owner: return "OWNER"
        case .admin: return "ADMIN"
        case .member: return "MEMBER"
        case .viewer: return "VIEWER"
        case .unknown(let s): return s
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireString: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireValue)
    }
}

public struct TeamMember: Sendable, Equatable {
    public let curvePublic: String
    public let edPublic: String?
    public let displayName: String?
    public let role: TeamRole
    public let profile: String?
    public let avatar: String?
    public let badge: String?
    public let uid: String?
    public let notifications: String?
    public let pendingOwner: Bool?
    public let online: Bool?
    public let pending: Bool?
    public let remaining: Int?
    public let totalUses: Int?
    public let inviteChannel: String?
    public let previewChannel: String?
    public let inviteHash: String?
}

public struct TeamMetadata: Sendable, Equatable {
    public let name: String
    public let topic: String?
    public let avatar: String?
    public let offline: Bool
}

public struct Contact: Sendable, Equatable {
    public let curvePublic: String
    public let edPublic: String?
    public let displayName: String?
    public let notifications: String?
    public let profile: String?
    public let avatar: String?
    public let uid: String?
    public let badge: String?
    public let pending: Bool
    public let hasDMChannel: Bool
}

public enum DisplayText {
    public static func escapeControlChars(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x5C {
                out.append(contentsOf: "\\\\".unicodeScalars)
            } else if v < 0x20 || (v >= 0x7F && v <= 0x9F)
                || v == 0x2028 || v == 0x2029
                || (v >= 0x202A && v <= 0x202E)
                || (v >= 0x2066 && v <= 0x2069)
                || v == 0x200E || v == 0x200F || v == 0x061C {
                out.append(contentsOf: "\\u{\(String(v, radix: 16, uppercase: true))}".unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    public static func quotedField(_ s: String) -> String {
        "\"" + escapeControlChars(s).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func trailingField(_ s: String?) -> String {
        guard let s else { return "-" }
        return s == "-" ? quotedField(s) : escapeControlChars(s)
    }
}

public struct ContactRequest: Sendable, Equatable {
    public let hash: String
    public let from: Contact
}

public struct MailboxNotification: Sendable, Equatable {
    public let box: String
    public let hash: String
    public let type: String
    public let author: String?
    public let time: Date?
    public let contentJSON: String
}

public struct NotificationHistoryPage: Sendable, Equatable {
    public let notifications: [MailboxNotification]
    public let exhausted: Bool
    public let unreadable: Int
    public let oldestHash: String?
}

public struct InvitePreview: Sendable, Equatable {
    public let teamName: String
    public let message: String?
    public let authorDisplayName: String?
    public let requiresPassword: Bool
}
