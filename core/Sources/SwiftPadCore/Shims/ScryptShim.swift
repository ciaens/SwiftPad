import CQuickJS
import Foundation

enum ScryptShim {
    static func install(bridge: JSBridge) throws {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }
        JS_SetPropertyStr(ctx, global, "__sp_scrypt_derive",
                          JS_NewCFunction(ctx, jsScryptDerive, "__sp_scrypt_derive", 2))

        let plumbing = """
        (function () {
            const pending = Object.create(null);
            globalThis.__sp_scrypt_resolve = function (id, b64) {
                const p = pending[id];
                if (!p) return;
                delete pending[id];
                p.resolve(b64);
            };
            globalThis.__sp_scrypt_reject = function (id, err) {
                const p = pending[id];
                if (!p) return;
                delete pending[id];
                p.reject(new Error(err));
            };
            globalThis.__sp_scrypt = function (password, salt) {
                return new Promise(function (resolve, reject) {
                    const id = __sp_scrypt_derive(password, salt);
                    pending[id] = { resolve: resolve, reject: reject };
                });
            };
        })();
        """
        try bridge.evalOnQueue(plumbing, filename: "scrypt.shim.js")
    }
}

private let jsScryptDerive: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx else { return sp_js_undefined() }
    guard let argv = argv, argc >= 2 else {
        return sp_js_throw_type_error(ctx, "scrypt: two string arguments required")
    }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else {
        return sp_js_throw_type_error(ctx, "scrypt: bridge unavailable")
    }
    var pwLen = 0
    guard let pwCStr = JS_ToCStringLen(ctx, &pwLen, argv[0]) else { return sp_js_exception() }
    let password = String(decoding: UnsafeRawBufferPointer(start: pwCStr, count: pwLen), as: UTF8.self)
    JS_FreeCString(ctx, pwCStr)
    var saltLen = 0
    guard let saltCStr = JS_ToCStringLen(ctx, &saltLen, argv[1]) else { return sp_js_exception() }
    let salt = String(decoding: UnsafeRawBufferPointer(start: saltCStr, count: saltLen), as: UTF8.self)
    JS_FreeCString(ctx, saltCStr)

    let id = bridge.nextScryptId
    bridge.nextScryptId += 1

    Task.detached(priority: .userInitiated) { [weak bridge] in
        do {
            var derived = try Scrypt.deriveCryptPadLogin(password: password, salt: salt)
            let b64Literal = JSSource.stringLiteral(Data(derived).base64EncodedString())
            derived.withUnsafeMutableBytes { Scrypt.zeroBytes($0) }
            guard let bridge = bridge else { return }
            bridge.queue.async {
                guard !bridge.closed else { return }
                do { _ = try bridge.evalOnQueue("__sp_scrypt_resolve(\(id), \(b64Literal));", filename: "scrypt.resolve.js") }
                catch { Trace.error(.bridge, "scrypt resolve dispatch failed id=\(id): \(error)") }
            }
        } catch {
            guard let bridge = bridge else { return }
            let msgLiteral = JSSource.stringLiteral("scrypt derivation failed: \(error)")
            bridge.queue.async {
                guard !bridge.closed else { return }
                do { _ = try bridge.evalOnQueue("__sp_scrypt_reject(\(id), \(msgLiteral));", filename: "scrypt.reject.js") }
                catch { Trace.error(.bridge, "scrypt reject dispatch failed id=\(id): \(error)") }
            }
        }
    }

    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}
