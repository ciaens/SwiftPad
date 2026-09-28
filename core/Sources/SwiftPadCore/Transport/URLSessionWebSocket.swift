import Foundation

#if canImport(Darwin)
public final class URLSessionWebSocket: NSObject, WebSocketProviding, URLSessionWebSocketDelegate, @unchecked Sendable {
    public var onOpen: (() -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onError: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let stateLock = NSLock()
    private var _closed = false

    public override init() {
        super.init()
    }

    public func connect(url: URL) {
        let config = URLSessionConfiguration.default
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = BridgeLimits.maxWebSocketFrameBytes
        self.session = session
        self.task = task
        task.resume()
        receiveLoop()
    }

    public func send(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            self.onError?(error.localizedDescription)
            if self.transitionToClosed() {
                self.onClose?("send failure: \(error.localizedDescription)")
                self.task?.cancel(with: .abnormalClosure, reason: nil)
                self.session?.finishTasksAndInvalidate()
            }
        }
    }

    public func close(reason: String?) {
        guard transitionToClosed() else { return }
        let reasonStr = reason ?? "closed"
        let data = reason?.data(using: .utf8)
        task?.cancel(with: .normalClosure, reason: data)
        session?.finishTasksAndInvalidate()
        onClose?(reasonStr)
    }

    private func transitionToClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if _closed { return false }
        _closed = true
        return true
    }

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _closed
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.onMessage?(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.onMessage?(text)
                    } else {
                        Trace.warn(.transport, "non-UTF-8 binary frame, len=\(data.count) — dropping")
                    }
                @unknown default:
                    break
                }
                if !self.isClosed { self.receiveLoop() }
            case .failure(let error):
                self.onError?(error.localizedDescription)
                if self.transitionToClosed() {
                    self.onClose?(error.localizedDescription)
                    self.task?.cancel(with: .abnormalClosure, reason: nil)
                    self.session?.finishTasksAndInvalidate()
                }
            }
        }
    }


    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, transitionToClosed() else { return }
        onError?(error.localizedDescription)
        onClose?(error.localizedDescription)
        self.session?.finishTasksAndInvalidate()
    }


    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code=\(closeCode.rawValue)"
        if transitionToClosed() {
            onClose?(reasonStr)
            self.session?.finishTasksAndInvalidate()
        }
    }
}

public struct URLSessionWebSocketFactory: WebSocketFactory {
    public init() {}
    public func make() -> WebSocketProviding { URLSessionWebSocket() }
}
#endif
