import CQuickJS
import Foundation

enum HTTPShim {
    static func install(bridge: JSBridge) throws {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }
        JS_SetPropertyStr(ctx, global, "__sp_http_get",
                          JS_NewCFunction(ctx, jsHttpGet, "__sp_http_get", 2))
        JS_SetPropertyStr(ctx, global, "__sp_http_post",
                          JS_NewCFunction(ctx, jsHttpPost, "__sp_http_post", 2))
        JS_SetPropertyStr(ctx, global, "__sp_http_stream_open",
                          JS_NewCFunction(ctx, jsHttpStreamOpen, "__sp_http_stream_open", 1))
        JS_SetPropertyStr(ctx, global, "__sp_http_stream_next",
                          JS_NewCFunction(ctx, jsHttpStreamNext, "__sp_http_stream_next", 1))
        JS_SetPropertyStr(ctx, global, "__sp_http_stream_close",
                          JS_NewCFunction(ctx, jsHttpStreamClose, "__sp_http_stream_close", 1))

        let plumbing = """
        (function () {
            const pending = Object.create(null);
            globalThis.__sp_http_callbacks = pending;
            globalThis.__sp_http_resolve = function (id, status, bodyBase64) {
                const p = pending[id];
                if (!p) return;
                delete pending[id];
                p.resolve({ status: status, bodyBase64: bodyBase64 });
            };
            globalThis.__sp_http_reject = function (id, err) {
                const p = pending[id];
                if (!p) return;
                delete pending[id];
                p.reject(new Error(err));
            };
            const streamPending = Object.create(null);
            globalThis.__sp_http_stream_callbacks = streamPending;
            globalThis.__sp_http_stream_resolve = function (tag, chunkBase64OrNull) {
                const p = streamPending[tag];
                if (!p) return;
                delete streamPending[tag];
                p.resolve(chunkBase64OrNull);
            };
            globalThis.__sp_http_stream_reject = function (tag, err) {
                const p = streamPending[tag];
                if (!p) return;
                delete streamPending[tag];
                p.reject(new Error(err));
            };
            globalThis.__sp_http = {
                get: function (url, headers) {
                    return new Promise(function (resolve, reject) {
                        let id;
                        if (headers === undefined) {
                            id = __sp_http_get(url);
                        } else {
                            const headersJson = JSON.stringify(headers);
                            if (typeof headersJson !== 'string') {
                                throw new TypeError('__sp_http.get: headers did not stringify to JSON');
                            }
                            id = __sp_http_get(url, headersJson);
                        }
                        pending[id] = { resolve: resolve, reject: reject };
                    });
                },
                post: function (url, jsonBody) {
                    return new Promise(function (resolve, reject) {
                        const id = __sp_http_post(url, jsonBody);
                        pending[id] = { resolve: resolve, reject: reject };
                    });
                },
                stream: function (url) {
                    const handle = __sp_http_stream_open(url);
                    return {
                        next: function () {
                            return new Promise(function (resolve, reject) {
                                const tag = __sp_http_stream_next(handle);
                                streamPending[tag] = { resolve: resolve, reject: reject };
                            });
                        },
                        close: function () {
                            __sp_http_stream_close(handle);
                        }
                    };
                }
            };
        })();
        """
        try bridge.evalOnQueue(plumbing, filename: "http.shim.js")
    }
}


final class HttpStreamHandle: @unchecked Sendable {
    let id: UInt64
    let url: URL
    let tagStream: AsyncStream<UInt64>
    let tagContinuation: AsyncStream<UInt64>.Continuation
    var pump: Task<Void, Never>?
    var terminalState: TerminalState?

    enum TerminalState {
        case eof
        case errorMessage(String)
        case closed
    }

    init(id: UInt64, url: URL) {
        self.id = id
        self.url = url
        let (s, c) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .unbounded)
        self.tagStream = s
        self.tagContinuation = c
    }
}


private func drainTag(bridge: JSBridge, handle: HttpStreamHandle, tag: UInt64, state: HttpStreamHandle.TerminalState) {
    bridge.queue.async { [weak bridge, weak handle] in
        guard let bridge = bridge, !bridge.closed else { return }
        handle?.terminalState = state
        let script: String
        switch state {
        case .eof:
            script = "__sp_http_stream_resolve(\(tag), null);"
        case .errorMessage(let msg):
            let msgLiteral = JSSource.stringLiteral(msg)
            script = "__sp_http_stream_reject(\(tag), \(msgLiteral));"
        case .closed:
            let msgLiteral = JSSource.stringLiteral("stream closed")
            script = "__sp_http_stream_reject(\(tag), \(msgLiteral));"
        }
        do { _ = try bridge.evalOnQueue(script, filename: "http.stream.drain.js") }
        catch { Trace.error(.transport, "stream drain dispatch failed tag=\(tag): \(error)") }
    }
}


private let jsHttpGet: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let client = bridge.httpClient else {
        return sp_js_throw_type_error(ctx, "HTTP: no client installed")
    }
    guard let cStr = JS_ToCString(ctx, argv[0]) else { return sp_js_exception() }
    let urlStr = String(cString: cStr)
    JS_FreeCString(ctx, cStr)
    let url: URL
    switch bridge.validateOrigin(urlStr: urlStr, expectedSchemes: ["http", "https"]) {
    case .accept(let parsed):
        url = parsed
    case .reject(let reason):
        Trace.warn(.transport, "HTTP allow-list rejected '\(JSBridge.redactFragmentSecrets(urlStr))': \(reason)")
        return sp_js_throw_type_error(ctx, "HTTP: URL rejected by origin allow-list")
    }

    var headers: [String: String]? = nil
    if argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1]) {
        guard let headersCStr = JS_ToCString(ctx, argv[1]) else { return sp_js_exception() }
        let headersJson = String(cString: headersCStr)
        JS_FreeCString(ctx, headersCStr)
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(headersJson.utf8)),
              let dict = parsed as? [String: String], !dict.isEmpty else {
            return sp_js_throw_type_error(ctx, "HTTP: headers must be a non-empty JSON object of strings")
        }
        for (name, value) in dict {
            let nameOK = !name.isEmpty && name.allSatisfy { c in
                if let a = c.asciiValue { return a > 0x20 && a < 0x7f } else { return false }
            }
            let valueOK = value.allSatisfy { c in
                if let a = c.asciiValue { return a >= 0x20 && a < 0x7f } else { return false }
            }
            if !nameOK || !valueOK {
                return sp_js_throw_type_error(ctx, "HTTP: header name or value contains forbidden characters")
            }
        }
        headers = dict
    }

    let id = bridge.nextHttpId
    bridge.nextHttpId += 1

    Task { [weak bridge] in
        do {
            let resp: HTTPResponse
            if let headers = headers {
                resp = try await client.get(url: url, headers: headers)
            } else {
                resp = try await client.get(url: url)
            }
            guard let bridge = bridge else { return }
            let bodyB64Literal = JSSource.stringLiteral(resp.body.base64EncodedString())
            bridge.queue.async {
                guard !bridge.closed else { return }
                let script = "__sp_http_resolve(\(id), \(resp.status), \(bodyB64Literal));"
                do { _ = try bridge.evalOnQueue(script, filename: "http.resolve.js") }
                catch { Trace.error(.transport, "http resolve dispatch failed id=\(id): \(error)") }
            }
        } catch {
            guard let bridge = bridge else { return }
            let msgLiteral = JSSource.stringLiteral(error.localizedDescription)
            bridge.queue.async {
                guard !bridge.closed else { return }
                let script = "__sp_http_reject(\(id), \(msgLiteral));"
                do { _ = try bridge.evalOnQueue(script, filename: "http.reject.js") }
                catch { Trace.error(.transport, "http reject dispatch failed id=\(id): \(error)") }
            }
        }
    }

    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}


private let jsHttpPost: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 2 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let client = bridge.httpClient else {
        return sp_js_throw_type_error(ctx, "HTTP-POST: no client installed")
    }
    guard let urlCStr = JS_ToCString(ctx, argv[0]) else { return sp_js_exception() }
    guard let bodyCStr = JS_ToCString(ctx, argv[1]) else {
        JS_FreeCString(ctx, urlCStr)
        return sp_js_exception()
    }
    let urlStr = String(cString: urlCStr)
    let bodyStr = String(cString: bodyCStr)
    JS_FreeCString(ctx, urlCStr)
    JS_FreeCString(ctx, bodyCStr)
    let url: URL
    switch bridge.validateOrigin(urlStr: urlStr, expectedSchemes: ["http", "https"]) {
    case .accept(let parsed):
        url = parsed
    case .reject(let reason):
        Trace.warn(.transport, "HTTP-POST allow-list rejected '\(JSBridge.redactFragmentSecrets(urlStr))': \(reason)")
        return sp_js_throw_type_error(ctx, "HTTP-POST: URL rejected by origin allow-list")
    }
    let bodyData = Data(bodyStr.utf8)

    let id = bridge.nextHttpId
    bridge.nextHttpId += 1

    Task { [weak bridge] in
        do {
            let resp = try await client.postJSON(url: url, body: bodyData, maxResponseBytes: nil)
            guard let bridge = bridge else { return }
            let bodyB64Literal = JSSource.stringLiteral(resp.body.base64EncodedString())
            bridge.queue.async {
                guard !bridge.closed else { return }
                let script = "__sp_http_resolve(\(id), \(resp.status), \(bodyB64Literal));"
                do { _ = try bridge.evalOnQueue(script, filename: "http.post.resolve.js") }
                catch { Trace.error(.transport, "http POST resolve dispatch failed id=\(id): \(error)") }
            }
        } catch {
            guard let bridge = bridge else { return }
            let msgLiteral = JSSource.stringLiteral(error.localizedDescription)
            bridge.queue.async {
                guard !bridge.closed else { return }
                let script = "__sp_http_reject(\(id), \(msgLiteral));"
                do { _ = try bridge.evalOnQueue(script, filename: "http.post.reject.js") }
                catch { Trace.error(.transport, "http POST reject dispatch failed id=\(id): \(error)") }
            }
        }
    }

    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}


private let jsHttpStreamOpen: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let client = bridge.httpClient else {
        return sp_js_throw_type_error(ctx, "HTTP-stream: no client installed")
    }
    guard let cStr = JS_ToCString(ctx, argv[0]) else { return sp_js_exception() }
    let urlStr = String(cString: cStr)
    JS_FreeCString(ctx, cStr)
    let url: URL
    switch bridge.validateOrigin(urlStr: urlStr, expectedSchemes: ["http", "https"]) {
    case .accept(let parsed):
        url = parsed
    case .reject(let reason):
        Trace.warn(.transport, "HTTP-stream allow-list rejected '\(JSBridge.redactFragmentSecrets(urlStr))': \(reason)")
        return sp_js_throw_type_error(ctx, "HTTP-stream: URL rejected by origin allow-list")
    }

    guard bridge.activeHttpStreams.count < BridgeLimits.maxActiveHttpStreams else {
        Trace.warn(.transport, "activeHttpStreams cap hit (\(BridgeLimits.maxActiveHttpStreams)) — rejecting open")
        return sp_js_throw_type_error(ctx, "HTTP-stream: active-stream cap reached")
    }
    let handleId = bridge.nextHttpStreamId
    bridge.nextHttpStreamId += 1
    let handle = HttpStreamHandle(id: handleId, url: url)
    bridge.activeHttpStreams[handleId] = handle

    handle.pump = Task { [weak bridge, weak handle] in
        guard let handle = handle else { return }
        var localDone: HttpStreamHandle.TerminalState? = nil
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator? = nil
        do {
            let httpStream = try await client.getStream(url: url, maxBytes: nil)
            if httpStream.status < 200 || httpStream.status >= 300 {
                localDone = .errorMessage("HTTP \(httpStream.status)")
            } else {
                iterator = httpStream.bytes.makeAsyncIterator()
            }
        } catch {
            localDone = .errorMessage(error.localizedDescription)
        }

        for await tag in handle.tagStream {
            if Task.isCancelled { return }
            if let done = localDone {
                guard let bridge = bridge else { return }
                drainTag(bridge: bridge, handle: handle, tag: tag, state: done)
                continue
            }
            do {
                let chunk = try await iterator?.next() ?? nil
                guard let bridge = bridge else { return }
                if let chunk = chunk {
                    let b64 = chunk.base64EncodedString()
                    bridge.queue.async { [weak bridge] in
                        guard let bridge = bridge, !bridge.closed else { return }
                        let bodyLiteral = JSSource.stringLiteral(b64)
                        let script = "__sp_http_stream_resolve(\(tag), \(bodyLiteral));"
                        do { _ = try bridge.evalOnQueue(script, filename: "http.stream.resolve.js") }
                        catch { Trace.error(.transport, "stream resolve dispatch failed tag=\(tag): \(error)") }
                    }
                } else {
                    localDone = .eof
                    drainTag(bridge: bridge, handle: handle, tag: tag, state: .eof)
                }
            } catch {
                let msg = error.localizedDescription
                guard let bridge = bridge else { return }
                localDone = .errorMessage(msg)
                drainTag(bridge: bridge, handle: handle, tag: tag, state: .errorMessage(msg))
            }
        }
    }

    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: handleId))
}

private let jsHttpStreamNext: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    var rawHandleId: Int32 = 0
    if JS_ToInt32(ctx, &rawHandleId, argv[0]) != 0 { return sp_js_exception() }
    let handleId = UInt64(UInt32(bitPattern: rawHandleId))
    guard let handle = bridge.activeHttpStreams[handleId] else {
        return sp_js_throw_type_error(ctx, "HTTP-stream: unknown handle")
    }

    let tag = bridge.nextHttpStreamTag
    bridge.nextHttpStreamTag += 1

    if let terminal = handle.terminalState {
        bridge.queue.async { [weak bridge] in
            guard let bridge = bridge, !bridge.closed else { return }
            let script: String
            let filename: String
            switch terminal {
            case .eof:
                script = "__sp_http_stream_resolve(\(tag), null);"
                filename = "http.stream.eof.js"
            case .errorMessage(let msg):
                let msgLiteral = JSSource.stringLiteral(msg)
                script = "__sp_http_stream_reject(\(tag), \(msgLiteral));"
                filename = "http.stream.terminal.js"
            case .closed:
                let msgLiteral = JSSource.stringLiteral("stream closed")
                script = "__sp_http_stream_reject(\(tag), \(msgLiteral));"
                filename = "http.stream.closed.js"
            }
            do { _ = try bridge.evalOnQueue(script, filename: filename) }
            catch { Trace.error(.transport, "stream terminal dispatch failed tag=\(tag): \(error)") }
        }
    } else {
        handle.tagContinuation.yield(tag)
    }

    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: tag))
}

private let jsHttpStreamClose: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    var rawHandleId: Int32 = 0
    if JS_ToInt32(ctx, &rawHandleId, argv[0]) != 0 { return sp_js_undefined() }
    let handleId = UInt64(UInt32(bitPattern: rawHandleId))
    guard let handle = bridge.activeHttpStreams.removeValue(forKey: handleId) else {
        return sp_js_undefined()
    }
    handle.terminalState = .closed
    handle.tagContinuation.finish()
    handle.pump?.cancel()
    return sp_js_undefined()
}
