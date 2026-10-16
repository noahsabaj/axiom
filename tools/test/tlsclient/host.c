/*
 * host.c - the C side of the TLS client's host test DLL (tls_client.dll),
 * driven from run.py with ctypes. Buffers what the client sends and what it
 * decrypts, and records its events; h_* call into it.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define API __declspec(dllexport)
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

u64 kc(void *target, const u64 *args, int *cf);
extern char tls_start[], tls_input[], tls_write[], tls_close[], tls_abort[];
extern char tls_error_text[], host_send[], host_ops[];
extern u32 tls_state, tls_error, tls_alert, tls_certs, tls_cert_bytes, tls_sigalg;

enum { EV_READY = 1, EV_CLOSED = 2, EV_FAIL = 4 };

static u8 *out, *app;
static size_t out_len, out_cap, app_len, app_cap;
static int events, fail_code, refuse_send;
static char *reply;             /* written from inside the READY handler */
static size_t reply_len;
static int reply_cf = -1;

static void put(u8 **buf, size_t *len, size_t *cap, const u8 *p, size_t n)
{
    if (*len + n > *cap) {
        *cap = (*len + n) * 2 + 4096;
        *buf = realloc(*buf, *cap);
    }
    memcpy(*buf + *len, p, n);
    *len += n;
}

static size_t take(u8 **buf, size_t *len, u8 *dst, size_t max)
{
    size_t n = *len < max ? *len : max;
    memcpy(dst, *buf, n);
    memmove(*buf, *buf + n, *len - n);
    *len -= n;
    return n;
}

static int cf;
#define P(x) ((u64)(uintptr_t)(x))
static u64 K(void *fn, u64 a, u64 b, u64 c)
{
    u64 args[6] = { a, b, c, 0, 0, 0 };
    return kc(fn, args, &cf);
}

int c_send(const u8 *p, u32 n)
{
    if (refuse_send) return 1;
    put(&out, &out_len, &out_cap, p, n);
    return 0;
}

void c_ready(void)
{
    events |= EV_READY;
    if (reply) {
        K(tls_write, 0, P(reply), reply_len);
        reply_cf = cf;
    }
}

void c_data(const u8 *p, u32 n) { put(&app, &app_len, &app_cap, p, n); }
void c_closed(void) { events |= EV_CLOSED; }
void c_fail(u32 code) { events |= EV_FAIL; fail_code = (int)code; }

API int h_start(const char *host)
{
    out_len = app_len = 0;
    events = fail_code = refuse_send = 0;
    reply_cf = -1;
    K(tls_start, P(host), P(host_send), P(host_ops));
    return cf ? -(int)tls_error : 0;
}
API void h_reply_on_ready(const char *p, size_t n)
{
    free(reply);
    reply = NULL;
    if (p) { reply = malloc(n); memcpy(reply, p, n); reply_len = n; }
}
API int h_reply_cf(void) { return reply_cf; }
API void h_input(const u8 *p, size_t n) { K(tls_input, 0, P(p), n); }
API int h_write(const u8 *p, size_t n) { K(tls_write, 0, P(p), n); return cf; }
API void h_close(void) { K(tls_close, 0, 0, 0); }
API void h_abort(void) { K(tls_abort, 0, 0, 0); }
API void h_refuse_send(int on) { refuse_send = on; }
API size_t h_out_len(void) { return out_len; }
API size_t h_take_out(u8 *dst, size_t max) { return take(&out, &out_len, dst, max); }
API size_t h_app_len(void) { return app_len; }
API size_t h_take_app(u8 *dst, size_t max) { return take(&app, &app_len, dst, max); }
API int h_events(void) { return events; }
API int h_fail_code(void) { return fail_code; }
API int h_state(void) { return (int)tls_state; }
API int h_alert(void) { return (int)tls_alert; }
API void h_info(int *certs, int *bytes, int *sigalg)
{
    *certs = (int)tls_certs; *bytes = (int)tls_cert_bytes; *sigalg = (int)tls_sigalg;
}
const char *tl_text(int code);     /* shim.asm */
API const char *h_error_text(int code) { return tl_text(code); }
