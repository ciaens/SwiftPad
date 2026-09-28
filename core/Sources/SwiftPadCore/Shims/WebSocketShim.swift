import CQuickJS
import Foundation

enum WebSocketShim {
    static func install(bridge: JSBridge) throws {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }

        JS_SetPropertyStr(ctx, global, "__sp_ws_create",
                          JS_NewCFunction(ctx, jsWsCreate, "__sp_ws_create", 1))
        JS_SetPropertyStr(ctx, global, "__sp_ws_send",
                          JS_NewCFunction(ctx, jsWsSend, "__sp_ws_send", 2))
        JS_SetPropertyStr(ctx, global, "__sp_ws_close",
                          JS_NewCFunction(ctx, jsWsClose, "__sp_ws_close", 2))

        let classScript = """
        (function () {
            const instances = new Map();
            globalThis.__sp_ws_dispatch = function (id, event, payload) {
                const ws = instances.get(id);
                if (!ws) return;
                if (event === 'open') {
                    ws.readyState = 1;
                    if (typeof ws.onopen === 'function') ws.onopen({});
                } else if (event === 'message') {
                    if (typeof ws.onmessage === 'function') ws.onmessage({ data: payload });
                } else if (event === 'close') {
                    ws.readyState = 3;
                    instances.delete(id);
                    if (typeof ws.onclose === 'function') ws.onclose({ reason: payload || '' });
                } else if (event === 'error') {
                    if (typeof ws.onerror === 'function') ws.onerror({ message: payload || '' });
                }
            };
            class SwiftPadWebSocket {
                constructor(url) {
                    this.url = url;
                    this.readyState = 0;
                    this.onopen = null;
                    this.onmessage = null;
                    this.onclose = null;
                    this.onerror = null;
                    this._id = __sp_ws_create(url);
                    instances.set(this._id, this);
                }
                send(data) {
                    if (typeof data !== 'string') data = String(data);
                    __sp_ws_send(this._id, data);
                }
                close(code, reason) {
                    __sp_ws_close(this._id, reason ? String(reason) : '');
                }
            }
            SwiftPadWebSocket.CONNECTING = 0;
            SwiftPadWebSocket.OPEN = 1;
            SwiftPadWebSocket.CLOSING = 2;
            SwiftPadWebSocket.CLOSED = 3;
            globalThis.WebSocket = SwiftPadWebSocket;
        })();
        """
        try bridge.evalOnQueue(classScript, filename: "websocket.shim.js")
    }

    static func dispatch(bridge: JSBridge, id: UInt64, event: String, payload: String) {
        guard !bridge.closed else { return }
        let eventLiteral = JSSource.stringLiteral(event)
        let payloadLiteral = JSSource.stringLiteral(payload)
        let script = "__sp_ws_dispatch(\(id), \(eventLiteral), \(payloadLiteral));"
        do { _ = try bridge.evalOnQueue(script, filename: "websocket.dispatch.js") }
        catch { Trace.error(.transport, "ws dispatch failed id=\(id) event=\(event): \(error)") }
    }
}


private let jsWsCreate: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let factory = bridge.webSocketFactory else {
        return sp_js_throw_type_error(ctx, "WebSocket: no factory installed")
    }
    guard bridge.activeWebSockets.count < BridgeLimits.maxActiveWebSockets else {
        Trace.warn(.transport, "activeWebSockets cap hit (\(BridgeLimits.maxActiveWebSockets)) — rejecting open")
        return sp_js_throw_type_error(ctx, "WebSocket: active-socket cap reached")
    }
    guard let cStr = JS_ToCString(ctx, argv[0]) else { return sp_js_exception() }
    let urlStr = String(cString: cStr)
    JS_FreeCString(ctx, cStr)
    let url: URL
    switch bridge.validateOrigin(urlStr: urlStr, expectedSchemes: ["ws", "wss"]) {
    case .accept(let parsed):
        url = parsed
    case .reject(let reason):
        Trace.warn(.transport, "WebSocket allow-list rejected '\(urlStr)': \(reason)")
        return sp_js_throw_type_error(ctx, "WebSocket: URL rejected by origin allow-list")
    }

    let id = bridge.nextWebSocketId
    bridge.nextWebSocketId += 1
    Trace.debug(.transport, "open id=\(id) url=\(url)")

    let ws = factory.make()
    bridge.activeWebSockets[id] = ws

    ws.onOpen = { [weak bridge] in
        Trace.debug(.transport, "id=\(id) open")
        guard let bridge = bridge else { return }
        bridge.queue.async {
            WebSocketShim.dispatch(bridge: bridge, id: id, event: "open", payload: "")
        }
    }
    ws.onMessage = { [weak bridge, weak ws] text in
        if text.utf8.count > BridgeLimits.maxWebSocketFrameBytes {
            Trace.warn(.transport, "id=\(id) frame rejected (\(text.utf8.count) bytes > \(BridgeLimits.maxWebSocketFrameBytes) cap) — closing socket")
            let errorPayload = #"{"code":"frame_too_large","bytes":\#(text.utf8.count)}"#
            ws?.close(reason: "frame_too_large")
            guard let bridge = bridge else { return }
            bridge.queue.async {
                WebSocketShim.dispatch(bridge: bridge, id: id, event: "error", payload: errorPayload)
                bridge.activeWebSockets.removeValue(forKey: id)
                WebSocketShim.dispatch(bridge: bridge, id: id, event: "close", payload: "frame_too_large")
            }
            return
        }
        Trace.debug(.transport, "id=\(id) msg \(text.prefix(120))")
        guard let bridge = bridge else { return }
        bridge.queue.async {
            WebSocketShim.dispatch(bridge: bridge, id: id, event: "message", payload: text)
        }
    }
    ws.onClose = { [weak bridge] reason in
        Trace.debug(.transport, "id=\(id) close reason=\(reason)")
        guard let bridge = bridge else { return }
        bridge.queue.async {
            bridge.activeWebSockets.removeValue(forKey: id)
            WebSocketShim.dispatch(bridge: bridge, id: id, event: "close", payload: reason)
        }
    }
    ws.onError = { [weak bridge] message in
        Trace.warn(.transport, "id=\(id) error \(message)")
        guard let bridge = bridge else { return }
        bridge.queue.async {
            WebSocketShim.dispatch(bridge: bridge, id: id, event: "error", payload: message)
        }
    }
    ws.connect(url: url)
    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}

private let jsWsSend: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 2 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    var id32: Int32 = 0
    guard JS_ToInt32(ctx, &id32, argv[0]) == 0 else { return sp_js_undefined() }
    let id = UInt64(UInt32(bitPattern: id32))
    guard let cStr = JS_ToCString(ctx, argv[1]) else { return sp_js_undefined() }
    let text = String(cString: cStr)
    JS_FreeCString(ctx, cStr)
    bridge.activeWebSockets[id]?.send(text)
    return sp_js_undefined()
}

private let jsWsClose: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    var id32: Int32 = 0
    guard JS_ToInt32(ctx, &id32, argv[0]) == 0 else { return sp_js_undefined() }
    let id = UInt64(UInt32(bitPattern: id32))
    var reason = ""
    if argc >= 2, let cStr = JS_ToCString(ctx, argv[1]) {
        reason = String(cString: cStr)
        JS_FreeCString(ctx, cStr)
    }
    bridge.activeWebSockets[id]?.close(reason: reason.isEmpty ? nil : reason)
    return sp_js_undefined()
}
