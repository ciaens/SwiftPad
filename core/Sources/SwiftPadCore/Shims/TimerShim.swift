import CQuickJS
import Foundation

enum TimerShim {
    static func install(bridge: JSBridge) {
        let ctx = bridge.context
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }

        JS_SetPropertyStr(ctx, global, "setTimeout",
                          JS_NewCFunction(ctx, jsSetTimeout, "setTimeout", 2))
        JS_SetPropertyStr(ctx, global, "setInterval",
                          JS_NewCFunction(ctx, jsSetInterval, "setInterval", 2))
        JS_SetPropertyStr(ctx, global, "clearTimeout",
                          JS_NewCFunction(ctx, jsClearTimer, "clearTimeout", 1))
        JS_SetPropertyStr(ctx, global, "clearInterval",
                          JS_NewCFunction(ctx, jsClearTimer, "clearInterval", 1))
    }

    static func schedule(bridge: JSBridge,
                         callback: JSValue,
                         delayMilliseconds: Int32,
                         repeating: Bool) -> UInt64? {
        if bridge.activeTimers.count >= BridgeLimits.maxActiveTimers {
            Trace.warn(.bridge, "activeTimers cap hit (\(BridgeLimits.maxActiveTimers)) — rejecting schedule")
            return nil
        }
        let id = bridge.nextTimerId
        bridge.nextTimerId += 1

        let retained = JS_DupValue(bridge.context, callback)
        let source = DispatchSource.makeTimerSource(queue: bridge.queue)
        let interval = DispatchTimeInterval.milliseconds(max(Int(delayMilliseconds), 0))
        if repeating {
            source.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            source.schedule(deadline: .now() + interval)
        }
        source.setEventHandler { [weak bridge] in
            guard let bridge = bridge else { return }
            guard let entry = bridge.activeTimers[id] else { return }
            bridge.withJSFrame {
            let ctx = bridge.context
            let fn = JS_DupValue(ctx, entry.callback)
            defer { JS_FreeValue(ctx, fn) }
            let rv = JS_Call(ctx, fn, sp_js_undefined(), 0, nil)
            if JS_IsException(rv) {
                let exc = JS_GetException(ctx)
                if let cs = JS_ToCString(ctx, exc) {
                    let raw = String(cString: cs)
                    JS_FreeCString(ctx, cs)
                    Trace.error(.bridge, "timer callback exception: \(JSBridge.redactFragmentSecrets(raw))")
                }
                JS_FreeValue(ctx, exc)
            }
            JS_FreeValue(ctx, rv)
            bridge.drainPendingJobs()
            if !repeating {
                cancel(bridge: bridge, id: id)
            }
            }
        }
        bridge.activeTimers[id] = JSBridge.ActiveTimer(source: source, callback: retained)
        source.resume()
        return id
    }

    static func cancel(bridge: JSBridge, id: UInt64) {
        guard let timer = bridge.activeTimers.removeValue(forKey: id) else { return }
        timer.source.cancel()
        JS_FreeValue(bridge.context, timer.callback)
    }
}


private let jsSetTimeout: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard JS_IsFunction(ctx, argv[0]) else {
        return sp_js_throw_type_error(ctx, "setTimeout: callback must be a function")
    }
    var delay: Int32 = 0
    if argc >= 2 { _ = JS_ToInt32(ctx, &delay, argv[1]) }
    guard let id = TimerShim.schedule(bridge: bridge, callback: argv[0], delayMilliseconds: delay, repeating: false) else {
        return sp_js_throw_type_error(ctx, "setTimeout: active-timer cap reached")
    }
    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}

private let jsSetInterval: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    guard JS_IsFunction(ctx, argv[0]) else {
        return sp_js_throw_type_error(ctx, "setInterval: callback must be a function")
    }
    var delay: Int32 = 0
    if argc >= 2 { _ = JS_ToInt32(ctx, &delay, argv[1]) }
    guard let id = TimerShim.schedule(bridge: bridge, callback: argv[0], delayMilliseconds: delay, repeating: true) else {
        return sp_js_throw_type_error(ctx, "setInterval: active-timer cap reached")
    }
    return JS_NewInt32(ctx, Int32(truncatingIfNeeded: id))
}

private let jsClearTimer: @convention(c) (OpaquePointer?, JSValue, Int32, UnsafeMutablePointer<JSValue>?) -> JSValue = { ctx, _, argc, argv in
    guard let ctx = ctx, let argv = argv, argc >= 1 else { return sp_js_undefined() }
    guard let bridge = JSBridge.bridge(for: ctx), !bridge.closed else { return sp_js_undefined() }
    var id: Int32 = 0
    if JS_ToInt32(ctx, &id, argv[0]) == 0 {
        TimerShim.cancel(bridge: bridge, id: UInt64(UInt32(bitPattern: id)))
    }
    return sp_js_undefined()
}
