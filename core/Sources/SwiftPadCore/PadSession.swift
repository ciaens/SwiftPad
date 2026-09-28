import Foundation

public final class PadSession: @unchecked Sendable {
    public let channel: String
    public let initialContent: PadContent

    let sessionId: String

    private let bridge: JSBridge
    private weak var owner: SwiftPadSession?
    private let lock = NSLock()
    private var _delegate: PadSessionDelegate?
    private var _closed = false
    private let _readOnly: Bool

    public var isReadOnly: Bool { _readOnly }

    init(sessionId: String,
         channel: String,
         initialContent: PadContent,
         readOnly: Bool,
         bridge: JSBridge,
         owner: SwiftPadSession,
         delegate: PadSessionDelegate?) {
        self.sessionId = sessionId
        self.channel = channel
        self.initialContent = initialContent
        self._readOnly = readOnly
        self.bridge = bridge
        self.owner = owner
        self._delegate = delegate
    }

    public func setDelegate(_ delegate: PadSessionDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        if !_closed {
            _delegate = delegate
        }
    }

    public func push(raw: String) async throws {
        let (isClosed, readOnly) = snapshotState()
        if isClosed { throw PadSessionError.padSessionFailed }
        if readOnly { throw PadSessionError.eReadOnly }

        let json: String
        do {
            json = try await bridge.callAsync("__swiftpad.pushPadSession",
                                              args: [sessionId, raw])
        } catch {
            throw SwiftPadSession.mapBridgeError(error)
        }
        try SwiftPadSession.checkWorkerEnvelope(Data(json.utf8))
    }

    private func snapshotState() -> (closed: Bool, readOnly: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (_closed, _readOnly)
    }

    public func close() {
        if markClosedAndClearDelegate() { return }
        unregisterFromOwner()
        dropJSHandleAsync()
    }

    public func closeAwait() async {
        let alreadyClosed = markClosedAndClearDelegate()
        if alreadyClosed { return }
        unregisterFromOwner()
        do {
            _ = try await bridge.callAsync("__swiftpad.closePadSession",
                                           args: [sessionId])
        } catch {
            Trace.debug(.bootstrap, "closeAwait dispatch failed: \(error)")
        }
    }

    private func markClosedAndClearDelegate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _closed { return true }
        _closed = true
        _delegate = nil
        return false
    }

    private func unregisterFromOwner() {
        if let owner = owner {
            owner.unregisterPadSession(sessionId: sessionId)
        }
    }

    private func dropJSHandleAsync() {
        let id = sessionId
        Task { [bridge] in
            do {
                _ = try await bridge.callAsync("__swiftpad.closePadSession",
                                               args: [id])
            } catch {
                Trace.debug(.bootstrap, "closePadSession dispatch failed: \(error)")
            }
        }
    }

    deinit {
        if !_closed {
            _closed = true
            unregisterFromOwner()
            dropJSHandleAsync()
        }
    }

    func dispatchPatch(raw: String) {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.padSession(self, didApplyPatch: raw)
    }

    func dispatchError(code: String) {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        let mapped = PadSessionError(rawValue: code) ?? .padSessionFailed
        delegate.padSession(self, didFail: mapped)
    }

    func dispatchDisconnect() {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.padSessionDidDisconnect(self)
    }

    func dispatchOwnerClosed() {
        lock.lock()
        if _closed {
            lock.unlock()
            return
        }
        _closed = true
        let delegate = _delegate
        _delegate = nil
        lock.unlock()

        delegate?.padSession(self, didFail: .sessionClosed)
        unregisterFromOwner()
        dropJSHandleAsync()
    }
}

public protocol PadSessionDelegate: AnyObject, Sendable {
    func padSession(_ session: PadSession, didApplyPatch raw: String)

    func padSession(_ session: PadSession, didFail code: PadSessionError)

    func padSessionDidDisconnect(_ session: PadSession)
}

public enum PadSessionError: String, Sendable, Error {
    case eDeleted = "EDELETED"
    case eExpired = "EEXPIRED"
    case eRestricted = "ERESTRICTED"
    case eUnknown = "EUNKNOWN"
    case eReadOnly = "EREADONLY"
    case padSessionFailed = "PAD_SESSION_FAILED"
    case sessionClosed = "SESSION_CLOSED"
}

final class WeakPadSessionBox: @unchecked Sendable {
    weak var ref: PadSession?
    init(_ ref: PadSession) { self.ref = ref }
}
