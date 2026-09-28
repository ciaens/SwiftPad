
import Foundation

public struct CalendarInfo: Sendable, Decodable {
    public let id: String
    public let title: String
    public let color: String
    public let readOnly: Bool
    public let loading: Bool
    public let owned: Bool
    public let restricted: Bool
    public let offline: Bool
    public let teams: [String]
}

public struct CalendarEvent: Sendable, Decodable {
    public let id: String
    public let title: String
    public let location: String
    public let body: String
    public let startMs: Double?
    public let endMs: Double?
    public let startDay: String?
    public let endDay: String?
    public let isAllDay: Bool
    public let reminders: [Double]
    public let isRecurring: Bool
    public let raw: String
}

public enum CalendarError: String, Sendable, Error {
    case timeout = "CALENDAR_TIMEOUT"
    case failed = "CALENDAR_FAILED"
    case notFound = "CALENDAR_NOT_FOUND"
    case notReady = "CALENDAR_NOT_READY"
    case readOnly = "CALENDAR_READ_ONLY"
    case teamWriteUnsupported = "CALENDAR_TEAM_WRITE_UNSUPPORTED"
    case eventNotFound = "EVENT_NOT_FOUND"
    case recurringEditUnsupported = "RECURRING_EDIT_UNSUPPORTED"
    case createUnconfirmed = "CALENDAR_CREATE_UNCONFIRMED"
}

extension CalendarError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .timeout: return "calendar command timed out (worker gave no reply)"
        case .failed: return "calendar command failed (non-string worker error)"
        case .notFound: return "calendar not found in this session"
        case .notReady: return "calendar still loading; retry when listCalendars shows loading == false"
        case .readOnly: return "no edit capability for this calendar (or it is cache-only/offline)"
        case .teamWriteUnsupported: return "team-calendar writes are not supported (phase-1 scope; use the web client)"
        case .eventNotFound: return "event not found in this calendar"
        case .recurringEditUnsupported: return "recurring events cannot be edited in this version; use the web client"
        case .createUnconfirmed: return "calendar was created but its id could not be confirmed; re-list calendars (do NOT retry the create)"
        }
    }
}

public struct CalendarEventChanges: Sendable {
    public var title: String?
    public var location: String?
    public var body: String?
    public var startMs: Double?
    public var endMs: Double?
    public var isAllDay: Bool?
    public var reminders: [Double]?

    public init(title: String? = nil, location: String? = nil,
                body: String? = nil, startMs: Double? = nil,
                endMs: Double? = nil, isAllDay: Bool? = nil,
                reminders: [Double]? = nil) {
        self.title = title
        self.location = location
        self.body = body
        self.startMs = startMs
        self.endMs = endMs
        self.isAllDay = isAllDay
        self.reminders = reminders
    }

    var asJSObject: [String: Any] {
        var out: [String: Any] = [:]
        if let title { out["title"] = title }
        if let location { out["location"] = location }
        if let body { out["body"] = body }
        if let startMs { out["startMs"] = startMs }
        if let endMs { out["endMs"] = endMs }
        if let isAllDay { out["isAllDay"] = isAllDay }
        if let reminders { out["reminders"] = reminders }
        return out
    }
}

extension SwiftPadSession {

    public func listCalendars() async throws -> [CalendarInfo] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let calendars: [CalendarInfo] }
        let data = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.listCalendars", args: [])
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).calendars
        } catch {
            throw Self.mapBridgeError(error)
        }
    }

    public func listCalendarEvents(calendarId: String) async throws -> [CalendarEvent] {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let events: [CalendarEvent] }
        let data = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.listCalendarEvents", args: [calendarId])
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).events
        } catch {
            throw Self.mapBridgeError(error)
        }
    }


    public func createCalendar(title: String, color: String) async throws -> String {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let id: String }
        let data = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.createCalendar", args: [title, color])
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).id
        } catch {
            throw Self.mapBridgeError(error)
        }
    }

    public func updateCalendar(calendarId: String, title: String? = nil,
                               color: String? = nil) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.updateCalendarMeta",
            args: [calendarId, title ?? NSNull(), color ?? NSNull()])
    }

    public func deleteCalendar(calendarId: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.deleteCalendar", args: [calendarId])
    }

    public func createCalendarEvent(calendarId: String, title: String,
                                    startMs: Double, endMs: Double,
                                    isAllDay: Bool = false,
                                    location: String = "", body: String = "",
                                    reminders: [Double] = [],
                                    timeZone: String = TimeZone.current.identifier) async throws -> String {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        struct Envelope: Decodable { let id: String }
        let fields: [String: Any] = [
            "title": title, "start": startMs, "end": endMs,
            "isAllDay": isAllDay, "location": location, "body": body,
            "reminders": reminders, "timeZone": timeZone,
        ]
        let data = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.createCalendarEvent",
            args: [calendarId, fields])
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).id
        } catch {
            throw Self.mapBridgeError(error)
        }
    }

    public func updateCalendarEvent(calendarId: String, eventId: String,
                                    changes: CalendarEventChanges) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.updateCalendarEvent",
            args: [calendarId, eventId, changes.asJSObject])
    }

    public func deleteCalendarEvent(calendarId: String, eventId: String) async throws {
        guard isAuthenticated else { throw SwiftPadError.notAuthenticated }
        _ = try await Self.calendarVerbData(
            bridge: bridge, path: "__swiftpad.deleteCalendarEvent",
            args: [calendarId, eventId])
    }

    static func calendarVerbData(bridge: JSBridge, path: String,
                                 args: [Any]) async throws -> Data {
        let json: String
        do {
            json = try await bridge.callAsync(path, args: args)
        } catch {
            throw mapBridgeError(error)
        }
        let data = Data(json.utf8)
        do {
            try checkWorkerEnvelope(data)
        } catch {
            if case SwiftPadError.workerError(let code, _) = error {
                if let calendarError = CalendarError(rawValue: code) {
                    throw calendarError
                }
                if code == "ENOENT" { throw CalendarError.notFound }
            }
            throw error
        }
        return data
    }
}
