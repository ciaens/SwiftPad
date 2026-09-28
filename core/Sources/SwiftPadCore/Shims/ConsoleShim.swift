import CQuickJS
import Foundation

enum ConsoleShim {
    static func install(bridge: JSBridge) {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }

        let console = JS_NewObject(ctx)
        JS_SetPropertyStr(ctx, console, "log",   JS_NewCFunction(ctx, jsConsoleInfo,  "log",   0))
        JS_SetPropertyStr(ctx, console, "info",  JS_NewCFunction(ctx, jsConsoleInfo,  "info",  0))
        JS_SetPropertyStr(ctx, console, "warn",  JS_NewCFunction(ctx, jsConsoleWarn,  "warn",  0))
        JS_SetPropertyStr(ctx, console, "error", JS_NewCFunction(ctx, jsConsoleError, "error", 0))
        JS_SetPropertyStr(ctx, console, "debug", JS_NewCFunction(ctx, jsConsoleDebug, "debug", 0))
        JS_SetPropertyStr(ctx, global, "console", console)

        JS_SetPropertyStr(ctx, global, "__sp_trace",
                          JS_NewCFunction(ctx, jsTrace, "__sp_trace", 3))
    }
}


private func concatArgs(ctx: OpaquePointer, argc: Int32, argv: UnsafeMutablePointer<JSValue>?) -> String {
    guard let argv = argv else { return "" }
    var parts: [String] = []
    for i in 0..<Int(argc) {
        if let cStr = JS_ToCString(ctx, argv[i]) {
            parts.append(String(cString: cStr))
            JS_FreeCString(ctx, cStr)
        }
    }
    return parts.joined(separator: " ")
}

private func cStringArg(_ ctx: OpaquePointer, _ value: JSValue) -> String? {
    guard let cs = JS_ToCString(ctx, value) else { return nil }
    defer { JS_FreeCString(ctx, cs) }
    return String(cString: cs)
}

private let jsConsoleInfo: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx else { return sp_js_undefined() }
    Trace.info(.js, concatArgs(ctx: ctx, argc: argc, argv: argv))
    return sp_js_undefined()
}

private let jsConsoleWarn: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx else { return sp_js_undefined() }
    Trace.warn(.js, concatArgs(ctx: ctx, argc: argc, argv: argv))
    return sp_js_undefined()
}

private let jsConsoleError: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx else { return sp_js_undefined() }
    Trace.error(.js, concatArgs(ctx: ctx, argc: argc, argv: argv))
    return sp_js_undefined()
}

private let jsConsoleDebug: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx else { return sp_js_undefined() }
    Trace.debug(.js, concatArgs(ctx: ctx, argc: argc, argv: argv))
    return sp_js_undefined()
}

private let jsTrace: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 3 else { return sp_js_undefined() }
    let catRaw = cStringArg(ctx, argv[0]) ?? "js"
    let lvlRaw = cStringArg(ctx, argv[1]) ?? "debug"
    let message = cStringArg(ctx, argv[2]) ?? ""
    let category = Trace.Category(rawValue: catRaw) ?? .js
    let level = Trace.Level.parse(lvlRaw) ?? .debug
    Trace.log(category, level, message)
    return sp_js_undefined()
}
