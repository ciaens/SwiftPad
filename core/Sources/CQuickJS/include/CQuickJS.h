#ifndef CQUICKJS_UMBRELLA_H
#define CQUICKJS_UMBRELLA_H

#include "../upstream/quickjs.h"
#include <stddef.h>
#include <sys/random.h>


static inline JSValue sp_js_undefined(void) { return JS_UNDEFINED; }
static inline JSValue sp_js_null(void)      { return JS_NULL; }
static inline JSValue sp_js_true(void)      { return JS_TRUE; }
static inline JSValue sp_js_false(void)     { return JS_FALSE; }
static inline JSValue sp_js_exception(void) { return JS_EXCEPTION; }

static inline JSValue sp_js_throw_type_error(JSContext *ctx, const char *msg) {
    return JS_ThrowTypeError(ctx, "%s", msg);
}

static inline int sp_random_bytes(void *buf, size_t len) {
    size_t remaining = len;
    unsigned char *p = (unsigned char *)buf;
    while (remaining > 0) {
        size_t chunk = remaining > 256 ? 256 : remaining;
        if (getentropy(p, chunk) != 0) return -1;
        p += chunk;
        remaining -= chunk;
    }
    return 0;
}

#endif
