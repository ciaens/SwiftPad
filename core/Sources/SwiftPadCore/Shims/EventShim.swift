import CQuickJS
import Foundation

enum EventShim {
    static func install(bridge: JSBridge) {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }
        JS_SetPropertyStr(ctx, global, "__sp_event",
                          JS_NewCFunction(ctx, jsEmitEvent, "__sp_event", 2))
    }
}

private let jsEmitEvent: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 2 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard let handler = bridge.eventHandler else { return sp_js_undefined() }
    guard let nameCStr = JS_ToCString(ctx, argv[0]) else { return sp_js_undefined() }
    let name = String(cString: nameCStr)
    JS_FreeCString(ctx, nameCStr)
    guard let payloadCStr = JS_ToCString(ctx, argv[1]) else { return sp_js_undefined() }
    let payload = String(cString: payloadCStr)
    JS_FreeCString(ctx, payloadCStr)
    handler(name, payload)
    return sp_js_undefined()
}
