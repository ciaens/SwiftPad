import Foundation
import NIOCore
import NIOWebSocket
import NIOSSL
import WebSocketKit
import SwiftPadCore

public final class NIOWebSocket: WebSocketProviding, @unchecked Sendable {
    public var onOpen: (() -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onError: ((String) -> Void)?

    private let stateLock = NSLock()
    private var _closed = false
    private var socket: WebSocket?

    static let maxFrameBytes = 1_048_576

    static let defaultClient = WebSocketClient(eventLoopGroupProvider: .shared(NIOTransportGroup.shared),
                                               configuration: makeConfiguration(tls: nil))

    static func makeConfiguration(tls: TLSConfiguration?) -> WebSocketClient.Configuration {
        var config = WebSocketClient.Configuration(tlsConfiguration: tls, maxFrameSize: maxFrameBytes)
        config.maxAccumulatedFrameSize = maxFrameBytes
        config.minNonFinalFragmentSize = 1024
        config.maxAccumulatedFrameCount = maxFrameBytes / 1024
        return config
    }

    private let client: WebSocketClient

    public convenience init() { self.init(client: Self.defaultClient) }

    init(client: WebSocketClient) { self.client = client }

    public func connect(url: URL) {
        guard let scheme = url.scheme, scheme == "ws" || scheme == "wss", let host = url.host else {
            let desc = "invalid websocket url"
            onError?(desc)
            if transitionToClosed() { onClose?(desc) }
            return
        }
        let port = url.port ?? (scheme == "wss" ? 443 : 80)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawPath = components?.percentEncodedPath ?? url.path
        let path = rawPath.isEmpty ? "/" : rawPath
        client.connect(scheme: scheme, host: host, port: port, path: path, query: components?.percentEncodedQuery,
                       onUpgrade: { [weak self] ws in
                           guard let self else { Self.closeOrphan(ws); return }
                           self.attach(ws)
                       })
            .whenFailure { [weak self] error in
                guard let self else { return }
                let desc: String
                if case WebSocketClient.Error.invalidResponseStatus(let head) = error {
                    desc = "websocket upgrade refused: HTTP \(head.status.code)"
                } else {
                    desc = "websocket connect failed: \(type(of: error))"
                }
                self.onError?(desc)
                if self.transitionToClosed() { self.onClose?(desc) }
            }
    }

    private func attach(_ ws: WebSocket) {
        stateLock.lock()
        let alreadyClosed = _closed
        if !alreadyClosed { socket = ws }
        stateLock.unlock()
        if alreadyClosed {
            Self.closeOrphan(ws)
            return
        }
        ws.pingInterval = .seconds(30)
        ws.onText { [weak self] _, text in self?.onMessage?(text) }
        ws.onBinary { [weak self] _, buffer in
            if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                self?.onMessage?(text)
            } else {
                Trace.warn(.transport, "non-UTF-8 binary frame, len=\(buffer.readableBytes) — dropping")
            }
        }
        ws.onClose.whenComplete { [weak self] _ in
            guard let self else { return }
            let code = ws.closeCode.map { "code=\($0)" } ?? "closed"
            if self.transitionToClosed() { self.onClose?(code) }
        }
        stateLock.lock(); let closedMeanwhile = _closed; stateLock.unlock()
        if !closedMeanwhile { onOpen?() }
    }

    public func send(_ text: String) {
        stateLock.lock(); let ws = socket; let closed = _closed; stateLock.unlock()
        guard let ws else {
            if !closed { Trace.warn(.transport, "send before upgrade completed — dropped, len=\(text.utf8.count)") }
            return
        }
        let promise = ws.eventLoop.makePromise(of: Void.self)
        ws.send(text, promise: promise)
        promise.futureResult.whenFailure { [weak self] error in
            guard let self else { return }
            let desc = "send failed: \(type(of: error))"
            self.onError?(desc)
            if self.transitionToClosed() {
                self.onClose?(desc)
                ws.close(code: .unexpectedServerError, promise: nil)
            }
        }
    }

    public func close(reason: String?) {
        guard transitionToClosed() else { return }
        stateLock.lock(); let ws = socket; stateLock.unlock()
        ws?.close(code: .normalClosure, promise: nil)
        onClose?(reason ?? "closed")
    }

    private static func closeOrphan(_ ws: WebSocket) {
        ws.pingInterval = .seconds(30)
        ws.close(code: .normalClosure, promise: nil)
    }

    private func transitionToClosed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if _closed { return false }
        _closed = true
        return true
    }
}

public struct NIOWebSocketFactory: WebSocketFactory {
    private let client: WebSocketClient

    public init() { self.client = NIOWebSocket.defaultClient }

    public init(additionalTrustRootPEMFiles: [String]) throws {
        let tls = try NIOTLS.clientConfiguration(additionalTrustRootPEMFiles: additionalTrustRootPEMFiles)
        self.client = WebSocketClient(eventLoopGroupProvider: .shared(NIOTransportGroup.shared),
                                      configuration: NIOWebSocket.makeConfiguration(tls: tls))
    }

    public func make() -> WebSocketProviding { NIOWebSocket(client: client) }
}
