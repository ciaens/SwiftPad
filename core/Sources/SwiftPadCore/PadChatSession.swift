import Foundation

public struct ChatMessage: Sendable, Equatable {
    public let sig: String
    public let authorCurvePublic: String
    public let authorName: String?
    public let time: Date
    public let text: String

    static func decode(_ obj: [String: Any]) -> ChatMessage? {
        guard obj["type"] as? String == "MSG",
              let sig = obj["sig"] as? String,
              let author = obj["author"] as? String,
              let timeMs = obj["time"] as? NSNumber,
              let text = obj["text"] as? String else { return nil }
        return ChatMessage(sig: sig,
                           authorCurvePublic: author,
                           authorName: obj["name"] as? String,
                           time: Date(timeIntervalSince1970: timeMs.doubleValue / 1000),
                           text: text)
    }
}

public enum PadChatError: String, Sendable, Error {
    case noChannel = "NO_CHANNEL"
    case forbidden = "FORBIDDEN"
    case noSuchChannel = "NO_SUCH_CHANNEL"
    case messengerDisabled = "MESSENGER_DISABLED"
    case chatNotInitialized = "CHAT_NOT_INITIALIZED"
    case padNotFound = "PAD_NOT_FOUND"
    case alreadyOpen = "CHAT_ALREADY_OPEN"
    case chatOpenTimeout = "CHAT_OPEN_TIMEOUT"
    case chatHistoryTimeout = "CHAT_HISTORY_TIMEOUT"
    case chatClosed = "CHAT_CLOSED"
    case unfriended = "UNFRIENDED"
    case noSuchFriend = "NO_SUCH_FRIEND"
    case chatFailed = "CHAT_FAILED"
    case chatTimeout = "CHAT_TIMEOUT"
    case sessionClosed = "SESSION_CLOSED"
}

extension PadChatError: CustomStringConvertible {
    public var description: String { rawValue }
}

public protocol PadChatSessionDelegate: AnyObject, Sendable {
    func chatSession(_ chat: PadChatSession, didReceive message: ChatMessage)
    func chatSessionDidClear(_ chat: PadChatSession)
    func chatSession(_ chat: PadChatSession, didFail error: PadChatError)
    func chatSessionDidDisconnect(_ chat: PadChatSession)
}

public final class PadChatSession: @unchecked Sendable {
    public let chatChannel: String
    public let padChannel: String
    public let initialMessages: [ChatMessage]

    let chatSessionId: String

    private let bridge: JSBridge
    private weak var owner: SwiftPadSession?
    private let lock = NSLock()
    private var _delegate: PadChatSessionDelegate?
    private var _closed = false

    init(chatSessionId: String,
         chatChannel: String,
         padChannel: String,
         initialMessages: [ChatMessage],
         bridge: JSBridge,
         owner: SwiftPadSession,
         delegate: PadChatSessionDelegate?) {
        self.chatSessionId = chatSessionId
        self.chatChannel = chatChannel
        self.padChannel = padChannel
        self.initialMessages = initialMessages
        self.bridge = bridge
        self.owner = owner
        self._delegate = delegate
    }

    public func setDelegate(_ delegate: PadChatSessionDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        if !_closed {
            _delegate = delegate
        }
    }

    public func loadMoreHistory(before sig: String, count: Int = 10) async throws -> [ChatMessage] {
        if isClosed() { throw PadChatError.chatClosed }
        let obj = try await SwiftPadSession.chatVerbObject(
            bridge: bridge, path: "__swiftpad.chatMoreHistory",
            args: [chatSessionId, sig, count])
        return Self.decodeMessagesArray(obj, context: "chatMoreHistory")
    }

    public func send(_ text: String) async throws {
        if isClosed() { throw PadChatError.chatClosed }
        _ = try await SwiftPadSession.chatVerbObject(
            bridge: bridge, path: "__swiftpad.sendChatMessage",
            args: [chatSessionId, text])
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
            _ = try await bridge.callAsync("__swiftpad.closePadChat", args: [chatSessionId])
        } catch {
            Trace.debug(.bootstrap, "closePadChat closeAwait dispatch failed: \(error)")
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
            owner.unregisterChatRoute(chatChannel: chatChannel)
        }
    }

    private func dropJSHandleAsync() {
        let id = chatSessionId
        Task { [bridge] in
            do {
                _ = try await bridge.callAsync("__swiftpad.closePadChat", args: [id])
            } catch {
                Trace.debug(.bootstrap, "closePadChat dispatch failed: \(error)")
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

    static func decodeMessagesArray(_ obj: [String: Any], context: String) -> [ChatMessage] {
        guard let raw = obj["messages"] as? [[String: Any]] else {
            Trace.warn(.bootstrap, "\(context): reply has no messages array; treating as empty")
            return []
        }
        var out: [ChatMessage] = []
        out.reserveCapacity(raw.count)
        for entry in raw {
            if let msg = ChatMessage.decode(entry) {
                out.append(msg)
            } else {
                Trace.debug(.bootstrap, "\(context): dropping undecodable message entry")
            }
        }
        return out
    }


    func dispatchMessage(_ message: ChatMessage) {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.chatSession(self, didReceive: message)
    }

    func dispatchClear() {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.chatSessionDidClear(self)
    }

    func dispatchDisconnect() {
        lock.lock()
        let delegate = _delegate
        let isClosed = _closed
        lock.unlock()
        guard !isClosed, let delegate = delegate else { return }
        delegate.chatSessionDidDisconnect(self)
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

        delegate?.chatSession(self, didFail: .sessionClosed)
        unregisterFromOwner()
        dropJSHandleAsync()
    }
}

protocol ChatRouteTarget: AnyObject, Sendable {
    func dispatchMessage(_ message: ChatMessage)
    func dispatchClear()
    func dispatchDisconnect()
    func dispatchOwnerClosed()
}

extension PadChatSession: ChatRouteTarget {}

final class ChatRouteBox: @unchecked Sendable {
    enum PendingTerminal { case ownerClosed, unfriended }

    private let lock = NSLock()
    private var pending: [ChatMessage] = []
    private weak var _session: (any ChatRouteTarget)?
    private var _pendingTerminal: PendingTerminal?
    private var _pendingClear = false

    var session: (any ChatRouteTarget)? {
        lock.lock()
        defer { lock.unlock() }
        return _session
    }

    func dispatch(_ message: ChatMessage) {
        lock.lock()
        if let session = _session {
            lock.unlock()
            session.dispatchMessage(message)
            return
        }
        pending.append(message)
        lock.unlock()
    }

    func dispatchClear() {
        lock.lock()
        if let session = _session {
            lock.unlock()
            session.dispatchClear()
            return
        }
        _pendingClear = true
        lock.unlock()
    }

    func dispatchOwnerClosed() {
        deliverOrLatch(.ownerClosed)
    }

    func dispatchUnfriended() {
        deliverOrLatch(.unfriended)
    }

    private func deliverOrLatch(_ terminal: PendingTerminal) {
        lock.lock()
        if let session = _session {
            lock.unlock()
            Self.deliver(terminal, to: session)
            return
        }
        if _pendingTerminal == nil {
            _pendingTerminal = terminal
        }
        lock.unlock()
    }

    func promote(to session: any ChatRouteTarget) -> (buffered: [ChatMessage], clearPending: Bool) {
        lock.lock()
        _session = session
        let buffered = pending
        pending = []
        let terminal = _pendingTerminal
        _pendingTerminal = nil
        let clearPending = _pendingClear
        _pendingClear = false
        lock.unlock()
        if let terminal = terminal {
            Self.deliver(terminal, to: session)
            return ([], false)
        }
        return (buffered, clearPending)
    }

    private static func deliver(_ terminal: PendingTerminal, to session: any ChatRouteTarget) {
        switch terminal {
        case .ownerClosed:
            session.dispatchOwnerClosed()
        case .unfriended:
            (session as? DMChannel)?.dispatchUnfriended()
        }
    }
}
