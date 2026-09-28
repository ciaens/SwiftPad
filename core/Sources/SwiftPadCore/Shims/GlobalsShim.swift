import CQuickJS
import Foundation

enum GlobalsShim {
    static func install(bridge: JSBridge, serverURL: URL) throws {
        let script = """
        (function () {
            const g = globalThis;
            if (typeof g.self === 'undefined')   g.self   = g;
            if (typeof g.window === 'undefined') g.window = g;
            \(locationSetup(for: serverURL))
            \(eventListenerStub)
            \(navigatorStub)
            \(urlPolyfill)
            \(indexedDBStub)
            \(localStorageStub)
            \(base64Polyfill)
        })();
        """
        try bridge.evalOnQueue(script, filename: "globals.shim.js")
        installCryptoGetRandomValues(bridge: bridge)
    }


    private static func locationSetup(for serverURL: URL) -> String {
        let hostname = serverURL.host ?? "localhost"
        let port = serverURL.port.map(String.init) ?? ""
        let scheme = serverURL.scheme ?? "https"
        let host = port.isEmpty ? hostname : "\(hostname):\(port)"
        let origin = "\(scheme)://\(host)"
        let pathname = serverURL.path.isEmpty ? "/" : serverURL.path
        return """
        if (typeof g.location === 'undefined') {
            g.location = {
                hostname: \(JSSource.stringLiteral(hostname)),
                host: \(JSSource.stringLiteral(host)),
                href: \(JSSource.stringLiteral(origin + pathname)),
                origin: \(JSSource.stringLiteral(origin)),
                protocol: \(JSSource.stringLiteral(scheme)) + ':',
                port: \(JSSource.stringLiteral(port)),
                pathname: \(JSSource.stringLiteral(pathname)),
                search: '',
                hash: ''
            };
        }
        """
    }

    private static let eventListenerStub = """
    if (typeof g.addEventListener !== 'function') {
        g.addEventListener = function () {};
        g.removeEventListener = function () {};
    }
    """

    private static let navigatorStub = """
    if (typeof g.navigator === 'undefined') {
        g.navigator = { userAgent: 'SwiftPad/0.1 (CryptPad worker host)' };
    }
    """

    private static let urlPolyfill = """
    if (typeof g.URL === 'undefined') {
        function URL(input, base) {
            let url = String(input);
            if (base !== undefined && base !== null) {
                const baseUrl = base instanceof URL ? base : new URL(base);
                if (!/^https?:\\/\\//.test(url)) {
                    if (url.startsWith('//')) {
                        url = baseUrl.protocol + url;
                    } else if (url.startsWith('/')) {
                        url = baseUrl.origin + url;
                    } else if (url.startsWith('?') || url.startsWith('#')) {
                        url = baseUrl.origin + baseUrl.pathname + url;
                    } else {
                        const dir = baseUrl.pathname.replace(/\\/[^\\/]*$/, '/');
                        url = baseUrl.origin + dir + url;
                    }
                }
            }
            const m = /^(https?):\\/\\/([^\\/:?#]+)(?::(\\d+))?([^?#]*)?(\\?[^#]*)?(#.*)?$/.exec(url);
            if (!m) throw new TypeError('Invalid URL: ' + input);
            this.protocol = m[1] + ':';
            this.hostname = m[2];
            this.host = m[3] ? this.hostname + ':' + m[3] : this.hostname;
            this.pathname = m[4] || '/';
            this.search = m[5] || '';
            this.hash = m[6] || '';
            this.origin = this.protocol + '//' + this.host;
            this.href = this.origin + this.pathname + this.search + this.hash;
        }
        URL.prototype.toString = function () { return this.href; };
        g.URL = URL;
    }
    """

    private static let indexedDBStub = """
    if (typeof g.indexedDB === 'undefined') {
        g.indexedDB = {
            open: function () {
                const req = { onsuccess: null, onerror: null, onupgradeneeded: null };
                setTimeout(function () {
                    if (typeof req.onerror === 'function') {
                        req.onerror({ target: { error: new Error('indexedDB unavailable in SwiftPad') } });
                    }
                }, 0);
                return req;
            },
            deleteDatabase: function () { return { onsuccess: null, onerror: null }; }
        };
    }
    """

    private static let localStorageStub = """
    if (typeof g.localStorage === 'undefined') {
        const store = {};
        let bytes = 0;
        const MAX_BYTES = \(BridgeLimits.maxLocalStorageBytes);
        const byteLen = function (s) {
            if (typeof s !== 'string') return 0;
            let n = 0;
            for (let i = 0; i < s.length; i++) {
                const c = s.charCodeAt(i);
                if (c < 0x80) n += 1;
                else if (c < 0x800) n += 2;
                else if (c >= 0xD800 && c <= 0xDBFF) { n += 4; i++; }
                else n += 3;
            }
            return n;
        };
        g.localStorage = {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
            setItem: function (k, v) {
                const ks = String(k);
                const vs = String(v);
                const prevValueLen = Object.prototype.hasOwnProperty.call(store, ks) ? byteLen(store[ks]) : 0;
                const prevKeyLen = Object.prototype.hasOwnProperty.call(store, ks) ? 0 : byteLen(ks);
                const delta = prevKeyLen + byteLen(vs) - prevValueLen;
                if (bytes + delta > MAX_BYTES) {
                    const err = new Error('QuotaExceededError: localStorage cap ' + MAX_BYTES + ' bytes');
                    err.name = 'QuotaExceededError';
                    throw err;
                }
                store[ks] = vs;
                bytes += delta;
            },
            removeItem: function (k) {
                const ks = String(k);
                if (Object.prototype.hasOwnProperty.call(store, ks)) {
                    bytes -= byteLen(ks) + byteLen(store[ks]);
                    delete store[ks];
                }
            },
            clear: function () {
                for (const k of Object.keys(store)) delete store[k];
                bytes = 0;
            }
        };
    }
    """

    private static let base64Polyfill = """
    if (typeof g.atob === 'undefined') {
        const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        const pad = (s) => s + '='.repeat((4 - (s.length % 4)) % 4);
        g.btoa = function (input) {
            const s = String(input);
            let out = '';
            for (let i = 0; i < s.length; i += 3) {
                const b1 = s.charCodeAt(i);
                const b2 = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
                const b3 = i + 2 < s.length ? s.charCodeAt(i + 2) : 0;
                out += A[b1 >> 2];
                out += A[((b1 & 3) << 4) | (b2 >> 4)];
                out += i + 1 < s.length ? A[((b2 & 15) << 2) | (b3 >> 6)] : '=';
                out += i + 2 < s.length ? A[b3 & 63] : '=';
            }
            return out;
        };
        g.atob = function (input) {
            const s = pad(String(input).replace(/\\s+/g, ''));
            let out = '';
            for (let i = 0; i < s.length; i += 4) {
                const c1 = A.indexOf(s[i]);
                const c2 = A.indexOf(s[i + 1]);
                const c3 = s[i + 2] === '=' ? -1 : A.indexOf(s[i + 2]);
                const c4 = s[i + 3] === '=' ? -1 : A.indexOf(s[i + 3]);
                out += String.fromCharCode((c1 << 2) | (c2 >> 4));
                if (c3 >= 0) out += String.fromCharCode(((c2 & 15) << 4) | (c3 >> 2));
                if (c4 >= 0) out += String.fromCharCode(((c3 & 3) << 6) | c4);
            }
            return out;
        };
    }
    """


    private static func installCryptoGetRandomValues(bridge: JSBridge) {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }
        let crypto = JS_NewObject(ctx)
        JS_SetPropertyStr(ctx, crypto, "getRandomValues",
                          JS_NewCFunction(ctx, jsGetRandomValues, "getRandomValues", 1))
        JS_SetPropertyStr(ctx, global, "crypto", crypto)
    }

}


private let jsGetRandomValues: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    let view = argv[0]

    var byteOffset: Int = 0
    var byteLength: Int = 0
    var bytesPerElement: Int = 0
    let bufVal = JS_GetTypedArrayBuffer(ctx, view, &byteOffset, &byteLength, &bytesPerElement)
    if JS_IsException(bufVal) {
        JS_FreeValue(ctx, bufVal)
        return sp_js_exception()
    }
    defer { JS_FreeValue(ctx, bufVal) }

    var totalSize: Int = 0
    guard let bytes = JS_GetArrayBuffer(ctx, &totalSize, bufVal) else {
        return sp_js_exception()
    }
    guard byteOffset >= 0, byteLength >= 0,
          !byteOffset.addingReportingOverflow(byteLength).overflow,
          byteOffset + byteLength <= totalSize else {
        return sp_js_throw_type_error(ctx, "getRandomValues: view bounds exceed buffer")
    }
    let dest = bytes.advanced(by: byteOffset)
    if sp_random_bytes(dest, byteLength) != 0 {
        return sp_js_throw_type_error(ctx, "getRandomValues: entropy source failed")
    }
    return JS_DupValue(ctx, view)
}
