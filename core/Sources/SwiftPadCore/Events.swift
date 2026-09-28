import Foundation

func reserializeJSON(_ value: Any?, escapeSlashes: Bool) -> String? {
    guard let value = value, !(value is NSNull) else { return nil }
    var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
    if !escapeSlashes { options.insert(.withoutEscapingSlashes) }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
          let s = String(data: data, encoding: .utf8) else { return nil }
    return s
}

public enum SwiftPadEvent: Sendable, Equatable {
    case driveChange(DriveChangePayload)
    case driveRemove(DriveRemovePayload)
    case networkDisconnect
    case networkReconnect
    case mailboxMessage(MailboxNotification)
    case mailboxViewed(box: String, hash: String)
    case contactDMReady(curvePublic: String)
}

public struct DriveChangePayload: Sendable, Equatable {
    public let path: [String]
    public let id: String?
    public let old: String?
    public let new: String?
}

public struct DriveRemovePayload: Sendable, Equatable {
    public let path: [String]
    public let id: String?
    public let old: String?
}

extension SwiftPadEvent {
    static func decode(name: String, payloadJSON: String) -> SwiftPadEvent? {
        switch name {
        case "NETWORK_DISCONNECT":
            return .networkDisconnect
        case "NETWORK_RECONNECT":
            return .networkReconnect
        case "DRIVE_CHANGE":
            guard let p = decodeDriveChangePayload(payloadJSON) else { return nil }
            return .driveChange(p)
        case "DRIVE_REMOVE":
            guard let p = decodeDriveRemovePayload(payloadJSON) else { return nil }
            return .driveRemove(p)
        case "MAILBOX_EVENT":
            return decodeMailboxEvent(payloadJSON)
        default:
            return nil
        }
    }

    private static func decodeMailboxEvent(_ json: String) -> SwiftPadEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = obj["ev"] as? String,
              let payload = obj["data"] as? [String: Any] else { return nil }
        switch ev {
        case "MESSAGE":
            guard let box = payload["type"] as? String,
                  let content = payload["content"] as? [String: Any],
                  let hash = content["hash"] as? String,
                  let msg = content["msg"] as? [String: Any] else { return nil }
            return .mailboxMessage(MailboxNotification(
                box: box,
                hash: hash,
                type: msg["type"] as? String ?? "",
                author: Self.boxAttestsAuthor(box)
                    ? (msg["author"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    : nil,
                time: decodeCtime(msg["ctime"]),
                contentJSON: reserialize(msg["content"]) ?? "null"))
        case "VIEWED":
            guard let box = payload["type"] as? String,
                  let hash = payload["hash"] as? String else { return nil }
            return .mailboxViewed(box: box, hash: hash)
        default:
            return nil
        }
    }

    private static func boxAttestsAuthor(_ box: String) -> Bool {
        box == "notifications" || box == "supportteam" || box.hasPrefix("team-")
    }

    private static func decodeCtime(_ value: Any?) -> Date? {
        guard let n = value as? NSNumber, n.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    private static func decodeDriveChangePayload(_ json: String) -> DriveChangePayload? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return DriveChangePayload(path: decodePathElements(obj["path"]),
                                  id: decodeStringOrNumber(obj["id"]),
                                  old: reserialize(obj["old"]),
                                  new: reserialize(obj["new"]))
    }

    private static func decodeDriveRemovePayload(_ json: String) -> DriveRemovePayload? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return DriveRemovePayload(path: decodePathElements(obj["path"]),
                                  id: decodeStringOrNumber(obj["id"]),
                                  old: reserialize(obj["old"]))
    }

    private static func decodePathElements(_ value: Any?) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { decodeStringOrNumber($0) }
    }

    private static func decodeStringOrNumber(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func reserialize(_ value: Any?) -> String? {
        reserializeJSON(value, escapeSlashes: false)
    }
}
