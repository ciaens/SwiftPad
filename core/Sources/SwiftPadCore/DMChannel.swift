import Foundation

public protocol DMChannelDelegate: AnyObject, Sendable {
    func dmChannel(_ channel: DMChannel, didReceive message: ChatMessage)
    func dmChannelDidClear(_ channel: DMChannel)
    func dmChannel(_ channel: DMChannel, didFail error: PadChatError)
    func dmChannelDidDisconnect(_ channel: DMChannel)
}

public final class DMChannel: @unchecked Sendable {
    public let contactCurvePublic: String
    public let channelId: String
    public let initialMessages: [ChatMessage]

    let dmSessionId: String

    private let bridge: JSBridge
    private weak var owner: SwiftPadSession?
    private let lock = NSLock()
    private var _delegate: DMChannelDelegate?
    private var _closed = false

    init(dmSessionId: String,
         contactCurvePublic: String,
         channelId: String,
         initialMessages: [ChatMessage],
         bridge: JSBridge,
         owner: SwiftPadSession,
         delegate: DMChannelDelegate?) {
        self.dmSessionId = dmSessionId
        self.contactCurvePublic = contactCurvePublic
        self.channelId = channelId
        self.initialMessages = initialMessages
        self.bridge = bridge
        self.owner = owner
        self._delegate = delegate
    }

    public func setDelegate(_ delegate: DMChannelDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        if !_closed {
            _delegate = delegate
        }
    }

    public func send(_ text: String) async throws {
        if isClosed() { throw PadChatError.chatClosed }
        _ = try await SwiftPadSession.chatVerbObject(
            bridge: bridge, path: "__swiftpad.sendDM",
            args: [dmSessionId, text])
    }

    public func loadMoreHistory(before sig: String, count: Int = 10) async throws -> [ChatMessage] {
        if isClosed() { throw PadChatError.chatClosed }
        let obj = try await SwiftPadSession.chatVerbObject(
            bridge: bridge, path: "__swiftpad.dmMoreHistory",
            args: [dmSessionId, sig, count])
        return PadChatSession.decodeMessagesArray(obj, context: "dmMoreHistory")
    }

    public func markRead(upTo sig: String) async throws {
        if isClosed() { throw PadChatError.chatClosed }
        _ = try await SwiftPadSession.chatVerbObject(
            bridge: bridge, path: "__swiftpad.dmMarkRead",
            args: [dmSessionId, sig])
    }

    public func close() {
        if markClosedAndClearDelegate() { return }
        unregisterFromOwner()
        dropJSHandleAsync()
    }

    public func closeAwait() async {
        if markClosedAndClearDelegate() { return }
        unregisterFromOwner()
        do {
            _ = try await bridge.callAsync("__swiftpad.closeDMChannel", args: [dmSessionId])
        } catch {
            Trace.debug(.bootstrap, "closeDMChannel closeAwait dispatch failed: \(error)")
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
            owner.unregisterChatRoute(chatChannel: channelId)
            owner.unregisterDMContact(curvePublic: contactCurvePublic)
        }
    }

    private func dropJSHandleAsync() {
        let id = dmSessionId
        Task { [bridge] in
            do {
                _ = try await bridge.callAsync("__swiftpad.closeDMChannel", args: [id])
            } catch {
                Trace.debug(.bootstrap, "closeDMChannel dispatch failed: \(error)")
            }
        }
    }

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _closed
    }

    deinit {
        if !_closed {
            _closed = true
            unregisterFromOwner()
            dropJSHandleAsync()
        }
    }


    func dispatchMessage(_ message: ChatMessage) {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.dmChannel(self, didReceive: message)
    }

    func dispatchClear() {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.dmChannelDidClear(self)
    }

    func dispatchDisconnect() {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.dmChannelDidDisconnect(self)
    }

    func dispatchOwnerClosed() {
        deliverTerminal(.sessionClosed)
    }

    func dispatchUnfriended() {
        deliverTerminal(.unfriended)
    }

    private func deliverTerminal(_ error: PadChatError) {
        lock.lock()
        if _closed {
            lock.unlock()
            return
        }
        _closed = true
        let delegate = _delegate
        _delegate = nil
        lock.unlock()

        delegate?.dmChannel(self, didFail: error)
        unregisterFromOwner()
        dropJSHandleAsync()
    }
}

extension DMChannel: ChatRouteTarget {}
