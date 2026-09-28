import Foundation

public protocol WebSocketProviding: AnyObject {
    func connect(url: URL)
    func send(_ text: String)
    func close(reason: String?)

    var onOpen: (() -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
}

public protocol WebSocketFactory: Sendable {
    func make() -> WebSocketProviding
}
