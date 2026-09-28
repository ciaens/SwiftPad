import CQuickJS
import Foundation
import Crypto

final class JSBridge: @unchecked Sendable {
    let runtime: OpaquePointer
    let context: OpaquePointer
    let queue = DispatchQueue(label: "org.swiftpad.js", qos: .userInitiated)

    var nextTimerId: UInt64 = 1
    var activeTimers: [UInt64: ActiveTimer] = [:]

    var nextWebSocketId: UInt64 = 1
    var activeWebSockets: [UInt64: WebSocketProviding] = [:]
    var webSocketFactory: WebSocketFactory?

    var nextHttpId: UInt64 = 1
    var httpClient: HTTPClient?

    var nextScryptId: UInt64 = 1

    var nextHttpStreamId: UInt64 = 1
    var nextHttpStreamTag: UInt64 = 1
    var activeHttpStreams: [UInt64: HttpStreamHandle] = [:]

    var pendingCalls: [String: (Result<String, Error>) -> Void] = [:]

    var eventHandler: ((String, String) -> Void)?

    private(set) var allowedOrigins: Set<Origin> = []

    private(set) var closed = false
    private var freed = false
    private var jsCallDepth = 0
    private var teardownDeferred = false

    struct ActiveTimer {
        let source: DispatchSourceTimer
        let callback: JSValue
    }

    private static let onBridgeQueueKey = DispatchSpecificKey<UUID>()
    private let bridgeUUID = UUID()
    private let resourceProvider: JSResourceProvider

    #if canImport(Darwin)
    convenience init() throws { try self.init(resourceProvider: .bundle) }
    #endif

    init(resourceProvider: JSResourceProvider) throws {
        self.resourceProvider = resourceProvider
        Trace.configureFromEnvironment()
        guard let rt = JS_NewRuntime() else { throw JSBridgeError.runtimeAllocationFailed }
        guard let ctx = JS_NewContext(rt) else {
            JS_FreeRuntime(rt)
            throw JSBridgeError.contextAllocationFailed
        }
        self.runtime = rt
        self.context = ctx
        JS_SetMaxStackSize(rt, 384 * 1024)
        JS_SetContextOpaque(ctx, Unmanaged.passUnretained(self).toOpaque())
        queue.setSpecific(key: Self.onBridgeQueueKey, value: bridgeUUID)
        installAsyncBridge()
        installTestAffordance()
    }

    private func installAsyncBridge() {
        let global = JS_GetGlobalObject(context)
        defer { JS_FreeValue(context, global) }
        JS_SetPropertyStr(context, global, "__sp_resolve",
                          JS_NewCFunction(context, jsResolve, "__sp_resolve", 2))
        JS_SetPropertyStr(context, global, "__sp_reject",
                          JS_NewCFunction(context, jsReject, "__sp_reject", 2))
    }

    private func installTestAffordance() {
        let source = """
        (function (g) {
            if (typeof g.__swiftpad === 'undefined') g.__swiftpad = {};
            if (typeof g.__swiftpad.test === 'undefined') g.__swiftpad.test = {};
            g.__swiftpad.test.neverResolve = function () {
                return new Promise(function () {});
            };
            g.__swiftpad.test.fastResolve = function () {
                return Promise.resolve(42);
            };
            g.__swiftpad.test.rejectWith = function (message) {
                return Promise.reject(new Error(String(message)));
            };
        })(globalThis);
        """
        source.withCString { cstr in
            let rv = JS_Eval(context, cstr, source.utf8.count, "test.affordance.js", Int32(JS_EVAL_TYPE_GLOBAL))
            JS_FreeValue(context, rv)
        }
    }

    func callAsync(_ path: String,
                   args: [Any] = [],
                   timeoutSeconds: TimeInterval = BridgeLimits.callAsyncTimeoutSeconds) async throws -> String {
        guard Self.isValidDotPath(path) else {
            throw JSBridgeError.invalidPath(path)
        }
        guard Self.allowedPaths.contains(path) else {
            throw JSBridgeError.invalidPath(path)
        }
        guard JSONSerialization.isValidJSONObject(args) else {
            throw JSBridgeError.typeMismatch("non-JSON args for \(path)")
        }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: args, options: [])
        guard let rawArgsJSON = String(data: data, encoding: .utf8) else {
            throw JSBridgeError.typeMismatch("non-UTF8 args JSON for \(path)")
        }
        let argsJSON = JSSource.escapeLineTerminators(rawArgsJSON)
        let idLiteral = JSSource.stringLiteral(id)
        let script = """
            (function () {
                const args = \(argsJSON);
                let settled = false;
                Promise.resolve()
                    .then(function () { return \(path).apply(null, args); })
                    .then(function (r) {
                        if (settled) return;
                        settled = true;
                        __sp_resolve(\(idLiteral), JSON.stringify(r === undefined ? null : r));
                    })
                    .catch(function (e) {
                        if (settled) return;
                        settled = true;
                        __sp_reject(\(idLiteral), e && e.message ? String(e.message) : String(e));
                    });
            })();
            """
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: JSBridgeError.contextAllocationFailed)
                    return
                }
                if self.closed {
                    continuation.resume(throwing: JSBridgeError.bridgeClosed)
                    return
                }
                guard self.pendingCalls.count < BridgeLimits.maxPendingCalls else {
                    Trace.warn(.bridge, "pendingCalls cap hit (\(BridgeLimits.maxPendingCalls)) — rejecting \(path)")
                    continuation.resume(throwing: JSBridgeError.resourceExhausted("pendingCalls"))
                    return
                }
                var resumed = false
                var timeoutWork: DispatchWorkItem?
                let finish: (Result<String, Error>) -> Void = { result in
                    if resumed { return }
                    resumed = true
                    timeoutWork?.cancel()
                    continuation.resume(with: result)
                }
                self.pendingCalls[id] = finish

                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if let cb = self.pendingCalls.removeValue(forKey: id) {
                        Trace.warn(.bridge, "callAsync timeout after \(timeoutSeconds)s for \(path)")
                        cb(.failure(JSBridgeError.callTimeout(path)))
                    }
                }
                timeoutWork = work
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

                do {
                    _ = try self.evalOnQueue(script, filename: "callAsync.js")
                } catch {
                    if self.pendingCalls.removeValue(forKey: id) != nil {
                        finish(.failure(error))
                    }
                }
            }
        }
    }

    func close() {
        syncOnQueue { closeLocked() }
    }

    func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.onBridgeQueueKey) == bridgeUUID {
            return body()
        }
        return queue.sync(execute: body)
    }

    var isClosedOnAnyThread: Bool {
        syncOnQueue { closed }
    }

    func closeLocked() {
        guard !closed else { return }
        closed = true
        for (_, timer) in activeTimers {
            timer.source.cancel()
            JS_FreeValue(context, timer.callback)
        }
        activeTimers.removeAll()
        for (_, ws) in activeWebSockets {
            ws.close(reason: "bridge close")
        }
        activeWebSockets.removeAll()
        for (_, handle) in activeHttpStreams {
            handle.terminalState = .closed
            handle.tagContinuation.finish()
            handle.pump?.cancel()
        }
        activeHttpStreams.removeAll()
        for (_, cb) in pendingCalls {
            cb(.failure(JSBridgeError.bridgeClosed))
        }
        pendingCalls.removeAll()
        if jsCallDepth > 0 {
            teardownDeferred = true
            return
        }
        finishTeardownLocked()
    }

    private func finishTeardownLocked() {
        drainPendingJobs()
        JS_SetContextOpaque(context, nil)
        JS_FreeContext(context)
        JS_FreeRuntime(runtime)
        freed = true
    }

    func withJSFrame<T>(_ body: () throws -> T) rethrows -> T {
        if jsCallDepth == 0 {
            JS_UpdateStackTop(runtime)
        }
        jsCallDepth += 1
        defer {
            jsCallDepth -= 1
            if jsCallDepth == 0 && teardownDeferred && !freed {
                teardownDeferred = false
                finishTeardownLocked()
            }
        }
        return try body()
    }

    deinit {
        if !freed { close() }
    }

    func installPlatformShims(serverURL: URL,
                              webSocketFactory: WebSocketFactory,
                              httpClient: HTTPClient) throws {
        try queue.sync {
            self.webSocketFactory = webSocketFactory
            self.httpClient = httpClient
            ConsoleShim.install(bridge: self)
            TimerShim.install(bridge: self)
            try GlobalsShim.install(bridge: self, serverURL: serverURL)
            try WebSocketShim.install(bridge: self)
            try HTTPShim.install(bridge: self)
            try ScryptShim.install(bridge: self)
            EventShim.install(bridge: self)
        }
    }

    @discardableResult
    func eval(_ script: String, filename: String = "<eval>") throws -> String {
        try queue.sync {
            if closed { throw JSBridgeError.bridgeClosed }
            return try evalOnQueue(script, filename: filename)
        }
    }

    func evalResource(name: String, extension ext: String = "js") throws {
        let fileName = name + "." + ext
        let data: Data
        do {
            data = try resourceProvider.load(fileName)
        } catch {
            Trace.debug(.bridge, "resource provider failed for \(fileName): \(error)")
            throw JSBridgeError.resourceNotFound(fileName)
        }
        try Self.verifyResource(name: fileName, data: data)
        guard let source = String(data: data, encoding: .utf8) else {
            throw JSBridgeError.typeMismatch("resource \(name).\(ext) is not UTF-8")
        }
        try eval(source, filename: "\(name).\(ext)")
    }

    static func verifyResource(name: String, data: Data) throws {
        guard let expected = ResourceHashes.expected[name] else {
            throw JSBridgeError.resourceUnpinned(name)
        }
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            Trace.error(.bridge,
                "resource \(name) tampered — expected=\(expected) actual=\(actual). " +
                "If you edited a resource, run scripts/regen-resource-hashes.sh."
            )
            throw JSBridgeError.resourceTampered(
                name: name, expected: expected, actual: actual
            )
        }
    }

    func evalInt32(_ script: String) throws -> Int32 {
        try queue.sync {
            if closed { throw JSBridgeError.bridgeClosed }
            return try withJSFrame {
                let result = evalRaw(script)
                defer { JS_FreeValue(context, result) }
                if JS_IsException(result) { throw makeJSException() }
                var out: Int32 = 0
                if JS_ToInt32(context, &out, result) != 0 {
                    throw JSBridgeError.typeMismatch("expected integer")
                }
                return out
            }
        }
    }

    @discardableResult
    func evalOnQueue(_ script: String, filename: String = "<eval>") throws -> String {
        try withJSFrame {
            let result = evalRaw(script, filename: filename)
            defer { JS_FreeValue(context, result) }
            if JS_IsException(result) { throw makeJSException() }
            let text = valueToString(result)
            drainPendingJobs()
            return text
        }
    }

    func drainPendingJobs() {
        withJSFrame { drainPendingJobsRaw() }
    }

    private func drainPendingJobsRaw() {
        while JS_IsJobPending(runtime) {
            var ctxOut: OpaquePointer?
            let r = JS_ExecutePendingJob(runtime, &ctxOut)
            if r < 0, let c = ctxOut {
                let exc = JS_GetException(c)
                if let cs = JS_ToCString(c, exc) {
                    let raw = String(cString: cs)
                    JS_FreeCString(c, cs)
                    Trace.error(.bridge, "pending job exception: \(Self.redactFragmentSecrets(raw))")
                }
                JS_FreeValue(c, exc)
            }
            if r == 0 { break }
        }
    }


    func evalRaw(_ script: String, filename: String = "<eval>") -> JSValue {
        let scriptByteCount = script.utf8.count
        return script.withCString { cSource in
            filename.withCString { cFilename in
                JS_Eval(context,
                        cSource,
                        scriptByteCount,
                        cFilename,
                        Int32(JS_EVAL_TYPE_GLOBAL))
            }
        }
    }

    func valueToString(_ value: JSValue) -> String {
        guard let cStr = JS_ToCString(context, value) else { return "" }
        defer { JS_FreeCString(context, cStr) }
        return String(cString: cStr)
    }

    func makeJSException() -> JSBridgeError {
        let exc = JS_GetException(context)
        defer { JS_FreeValue(context, exc) }
        var message = valueToString(exc)
        let stack = "stack".withCString { key in
            JS_GetPropertyStr(context, exc, key)
        }
        if !JS_IsUndefined(stack) {
            let stackStr = valueToString(stack)
            if !stackStr.isEmpty { message += "\n" + stackStr }
        }
        JS_FreeValue(context, stack)
        return .jsException(Self.redactFragmentSecrets(message))
    }

    private static let fragmentRedactionPattern: NSRegularExpression = {
        let pattern = #"(?:(?<=[\s"'(,:=;{<\[])|^)[^\s"'()<>\[\]{}]*#[A-Za-z0-9_/+=\-]{20,}"#
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    private static let bareBase64SecretPattern: NSRegularExpression = {
        let pattern = #"(?:(?<=[\s"'(,:=;{<\[])|^)[A-Za-z0-9_/+=\-]{200,}"#
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    private static let pathHashRedactionPattern: NSRegularExpression = {
        let pattern = #"/[123]/(?:[a-z]+/)?(?:(?:edit|view)/)?[A-Za-z0-9_\-+=]{20,}(?:/[A-Za-z0-9_\-+=]{20,})?/?"#
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    static func redactFragmentSecrets(_ message: String) -> String {
        let bareStripped = Self.redactBareBase64Secrets(message)
        let fragmentStripped = fragmentRedactionPattern.stringByReplacingMatches(
            in: bareStripped,
            options: [],
            range: NSRange(bareStripped.startIndex..., in: bareStripped),
            withTemplate: "<redacted-fragment>"
        )
        return pathHashRedactionPattern.stringByReplacingMatches(
            in: fragmentStripped,
            options: [],
            range: NSRange(fragmentStripped.startIndex..., in: fragmentStripped),
            withTemplate: "<redacted-hash>"
        )
    }

    private static func redactBareBase64Secrets(_ message: String) -> String {
        let range = NSRange(message.startIndex..., in: message)
        return bareBase64SecretPattern.stringByReplacingMatches(
            in: message,
            options: [],
            range: range,
            withTemplate: "<redacted-bare-secret>"
        )
    }

    static func bridge(for ctx: OpaquePointer) -> JSBridge? {
        guard let raw = JS_GetContextOpaque(ctx) else { return nil }
        return Unmanaged<JSBridge>.fromOpaque(raw).takeUnretainedValue()
    }


    func setAllowedOrigins(_ origins: Set<Origin>) {
        queue.sync { self.allowedOrigins = origins }
    }

    enum OriginValidation {
        case accept(URL)
        case reject(reason: String)
    }

    func validateOrigin(urlStr: String, expectedSchemes: Set<String>) -> OriginValidation {
        guard let comps = URLComponents(string: urlStr) else {
            return .reject(reason: "URL parse failed")
        }
        guard let scheme = comps.scheme?.lowercased() else {
            return .reject(reason: "missing scheme")
        }
        guard expectedSchemes.contains(scheme) else {
            return .reject(reason: "scheme \(scheme) not in \(expectedSchemes.sorted())")
        }
        if comps.user != nil || comps.password != nil {
            return .reject(reason: "userinfo not allowed")
        }
        if comps.fragment != nil {
            return .reject(reason: "fragment not allowed")
        }
        guard let url = comps.url, let origin = Origin(url: url) else {
            return .reject(reason: "could not derive origin")
        }
        guard allowedOrigins.contains(origin) else {
            return .reject(reason: "origin \(origin.scheme)://\(origin.host):\(origin.port) not allow-listed")
        }
        return .accept(url)
    }

    private static let jsPathRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*){0,7}$"#
    )
    static func isValidDotPath(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 128 else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return jsPathRegex.firstMatch(in: s, range: range) != nil
    }

    static let allowedPaths: Set<String> = [
        "__swiftpad.anonymous",
        "__swiftpad.rpc",
        "__swiftpad.getDrive",
        "__swiftpad.getPadMetadata",
        "__swiftpad.createPad",
        "__swiftpad.initialize",
        "__swiftpad.deletePad",
        "__swiftpad.destroyPad",
        "__swiftpad.setPadTitle",
        "__swiftpad.pinPads",
        "__swiftpad.unpinPads",
        "__swiftpad.getDriveTree",
        "__swiftpad.movePad",
        "__swiftpad.purgeTrash",
        "__swiftpad.getPadAttribute",
        "__swiftpad.setPadAttribute",
        "__swiftpad.getAttribute",
        "__swiftpad.setAttribute",
        "__swiftpad.getPadAttributeRaw",
        "__swiftpad.getAttributeRaw",
        "__swiftpad.setDisplayName",
        "__swiftpad.getPinnedUsage",
        "__swiftpad.getPinLimit",
        "__swiftpad.listTeams",
        "__swiftpad.getTeamMetadata",
        "__swiftpad.getTeamRoster",
        "__swiftpad.listContacts",
        "__swiftpad.listIncomingContactRequests",
        "__swiftpad.listNotifications",
        "__swiftpad.markNotificationRead",
        "__swiftpad.notificationHistory",
        "__swiftpad.sendContactRequest",
        "__swiftpad.cancelContactRequest",
        "__swiftpad.answerContactRequest",
        "__swiftpad.removeContact",
        "__swiftpad.getTeamDrive",
        "__swiftpad.getTeamPinnedUsage",
        "__swiftpad.getTeamPinLimit",
        "__swiftpad.createTeam",
        "__swiftpad.leaveTeam",
        "__swiftpad.deleteTeam",
        "__swiftpad.setTeamMetadata",
        "__swiftpad.inviteToTeam",
        "__swiftpad.removeUser",
        "__swiftpad.createInviteLink",
        "__swiftpad.previewInviteLink",
        "__swiftpad.acceptInviteLink",
        "__swiftpad.getDeletedPads",
        "__swiftpad.signInWithCachedKeys",
        "__swiftpad.getLoginSalt",
        "__swiftpad.signUp",
        "__swiftpad.getSignUpRules",
        "__swiftpad.getShareLinks",
        "__swiftpad.getAccountInfo",
        "__swiftpad.getProfile",
        "__swiftpad.setProfileAvatar",
        "__swiftpad.setProfileDescription",
        "__swiftpad.setProfileUrl",
        "__swiftpad.getPadContent",
        "__swiftpad.setPadContent",
        "__swiftpad.openPadSession",
        "__swiftpad.confirmPadSession",
        "__swiftpad.pushPadSession",
        "__swiftpad.closePadSession",
        "__swiftpad.openPadChat",
        "__swiftpad.chatRooms",
        "__swiftpad.chatMoreHistory",
        "__swiftpad.sendChatMessage",
        "__swiftpad.closePadChat",
        "__swiftpad.openDMChannel",
        "__swiftpad.dmRooms",
        "__swiftpad.sendDM",
        "__swiftpad.dmMoreHistory",
        "__swiftpad.dmMarkRead",
        "__swiftpad.closeDMChannel",
        "__swiftpad.listCalendars",
        "__swiftpad.listCalendarEvents",
        "__swiftpad.createCalendar",
        "__swiftpad.updateCalendarMeta",
        "__swiftpad.deleteCalendar",
        "__swiftpad.createCalendarEvent",
        "__swiftpad.updateCalendarEvent",
        "__swiftpad.deleteCalendarEvent",
        "__swiftpad.serializeDriveForCache",
        "__swiftpad.streamFileContent_open",
        "__swiftpad.streamFileContent_next",
        "__swiftpad.streamFileContent_close",
        "__swiftpad.uploadFile_open",
        "__swiftpad.uploadFile_writeChunks",
        "__swiftpad.uploadFile_finalize",
        "__swiftpad.uploadFile_cancel",
        "__swiftpad.test.neverResolve",
        "__swiftpad.test.fastResolve",
        "__swiftpad.test.rejectWith",
        "__swiftpad.test.padSessionsSize",
        "__swiftpad.test.authApiOrigin",
        "__swiftpad.test.deriveInviteMaterial",
        "__swiftpad.test.messengerCmd",
        "__swiftpad.test.profileCmd",
        "__swiftpad.test.calendarCmd",
        "__swiftpad.test.mailboxCmd",
        "__swiftpad.test.historyPendingTxid",
        "__swiftpad.test.removeLoginBlock",
        "__swiftpad.test.seedLegacyChannel",
    ]
}

public enum JSBridgeError: Error, Equatable, Sendable {
    case runtimeAllocationFailed
    case contextAllocationFailed
    case jsException(String)
    case typeMismatch(String)
    case resourceNotFound(String)
    case jsRejection(String)
    case bridgeClosed
    case invalidPath(String)
    case resourceExhausted(String)
    case callTimeout(String)
    case resourceTampered(name: String, expected: String, actual: String)
    case resourceUnpinned(String)
}

public struct Origin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = comps.scheme?.lowercased(),
            let host = comps.percentEncodedHost?.lowercased(),
            !host.isEmpty
        else { return nil }
        guard let p = comps.port ?? Self.defaultPort(for: scheme) else { return nil }
        guard (1...65535).contains(p) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = p
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https", "wss": return 443
        case "http", "ws":   return 80
        default:             return nil
        }
    }
}

enum BridgeLimits {
    static let maxActiveTimers = 1024
    static let maxActiveWebSockets = 64
    static let maxActiveHttpStreams = 32
    static let maxPendingCalls = 512
    static let maxLocalStorageBytes = 1_048_576
    static let maxHTTPBodyBytes = 52_428_800
    static let maxFileBlobUploadBytes = 52_428_800
    static let uploadPlainChunkSize = 131_072
    static let maxWebSocketFrameBytes = 1_048_576
    static let callAsyncTimeoutSeconds: TimeInterval = 45
}


private func readCStringArg(_ ctx: OpaquePointer, _ value: JSValue) -> String? {
    guard let cStr = JS_ToCString(ctx, value) else { return nil }
    defer { JS_FreeCString(ctx, cStr) }
    return String(cString: cStr)
}

private let jsResolve: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 2 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let id = readCStringArg(ctx, argv[0]),
          let payload = readCStringArg(ctx, argv[1]) else { return sp_js_undefined() }
    if let cb = bridge.pendingCalls.removeValue(forKey: id) {
        cb(.success(payload))
    }
    return sp_js_undefined()
}

private let jsReject: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 2 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let id = readCStringArg(ctx, argv[0]),
          let message = readCStringArg(ctx, argv[1]) else { return sp_js_undefined() }
    if let cb = bridge.pendingCalls.removeValue(forKey: id) {
        cb(.failure(JSBridgeError.jsRejection(JSBridge.redactFragmentSecrets(message))))
    }
    return sp_js_undefined()
}
