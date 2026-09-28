import Foundation
import Crypto

public enum Trace {
    public enum Category: String, Sendable {
        case js, transport, bridge, bootstrap, session
    }

    public enum Level: Int, Sendable, Comparable {
        case debug = 0, info, warn, error
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        var label: String {
            switch self {
            case .debug: return "debug"
            case .info:  return "info"
            case .warn:  return "warn"
            case .error: return "error"
            }
        }
        static func parse(_ raw: String) -> Self? {
            switch raw.lowercased() {
            case "debug": return .debug
            case "info":  return .info
            case "warn", "warning": return .warn
            case "error": return .error
            default: return nil
            }
        }
    }

    public typealias Sink = @Sendable (Category, Level, String) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _minimumLevel: Level = .info
    nonisolated(unsafe) private static var _sink: Sink = defaultSink

    public static var minimumLevel: Level {
        lock.lock(); defer { lock.unlock() }
        return _minimumLevel
    }
    public static var sink: Sink {
        lock.lock(); defer { lock.unlock() }
        return _sink
    }

    public static let defaultSink: Sink = { cat, lvl, msg in
        let line = "[\(lvl.label):\(cat.rawValue)] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public static func configure(sink: Sink? = nil, minimumLevel: Level? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let sink = sink { _sink = sink }
        if let minimumLevel = minimumLevel { _minimumLevel = minimumLevel }
    }

    public static func withSink<T>(_ sink: @escaping Sink, body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = _sink
        _sink = sink
        lock.unlock()
        defer {
            lock.lock()
            _sink = previous
            lock.unlock()
        }
        return try body()
    }

    public static func log(_ category: Category, _ level: Level, _ message: @autoclosure () -> String) {
        let (threshold, activeSink): (Level, Sink) = {
            lock.lock(); defer { lock.unlock() }
            return (_minimumLevel, _sink)
        }()
        guard level >= threshold else { return }
        activeSink(category, level, message())
    }

    public static func debug(_ category: Category, _ message: @autoclosure () -> String) { log(category, .debug, message()) }
    public static func info (_ category: Category, _ message: @autoclosure () -> String) { log(category, .info,  message()) }
    public static func warn (_ category: Category, _ message: @autoclosure () -> String) { log(category, .warn,  message()) }
    public static func error(_ category: Category, _ message: @autoclosure () -> String) { log(category, .error, message()) }

    public static func hashShort(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    public static func configureFromEnvironment() {
        if let raw = ProcessInfo.processInfo.environment["SWIFTPAD_LOG"],
           let lvl = Level.parse(raw) {
            configure(minimumLevel: lvl)
        }
    }
}
