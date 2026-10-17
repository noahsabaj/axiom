/*
 * host.c - the C side of the TLS client's host test DLL (tls_client.dll),
 * driven from run.py with ctypes. Holds NS sessions; h_select picks the one
 * every other h_* acts on. For each it buffers what the client sends and
 * what it decrypts, and records its events.
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
extern u64 x509_extra;
/* shim.asm: TLS_SESSION, then the offsets of TLS_STATE, TLS_ERROR,
 * TLS_ALERT, TLS_CERTS, TLS_CERT_BYTES, TLS_SIGALG, TLS_CERT_ERR,
 * TLS_VERIFIED, TLS_HAVE_KEY, TLS_ANCHOR, TLS_DEPTH */
extern u64 tls_layout[];
enum { L_SIZE, L_STATE, L_ERROR, L_ALERT, L_CERTS, L_CERT_BYTES, L_SIGALG, L_CERT_ERR,
       L_VERIFIED, L_HAVE_KEY, L_ANCHOR, L_DEPTH };

enum { EV_READY = 1, EV_CLOSED = 2, EV_FAIL = 4 };
#define NS 4

static struct sess {
    u8 *mem;                    /* the session tls.asm keeps */
    u8 *out, *app;
    size_t out_len, out_cap, app_len, app_cap;
    int events, fail_code, refuse_send;
    char *reply;                /* written from inside the READY handler */
    size_t reply_len;
    int reply_cf;
} ss[NS];
static struct sess *s = &ss[0];

static u32 f32(struct sess *x, int f) { return *(u32 *)(x->mem + tls_layout[f]); }

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
static u64 K5(void *fn, u64 a, u64 b, u64 c, u64 d, u64 e, u64 f)
{
    u64 args[6] = { a, b, c, d, e, f };
    return kc(fn, args, &cf);
}
#define K(fn, a, b, c) K5(fn, a, b, c, 0, 0, 0)

/* the session tls.asm names in a call back */
static struct sess *of(const u8 *mem)
{
    for (int i = 0; i < NS; i++)
        if (ss[i].mem == mem) return &ss[i];
    abort();
}

int c_send(const u8 *mem, const u8 *p, u32 n)
{
    struct sess *x = of(mem);
    if (x->refuse_send) return 1;
    put(&x->out, &x->out_len, &x->out_cap, p, n);
    return 0;
}

void c_ready(const u8 *mem)
{
    struct sess *x = of(mem);
    x->events |= EV_READY;
    if (x->reply) {
        K(tls_write, P(mem), P(x->reply), x->reply_len);
        x->reply_cf = cf;
    }
}

void c_data(const u8 *mem, const u8 *p, u32 n)
{
    struct sess *x = of(mem);
    put(&x->app, &x->app_len, &x->app_cap, p, n);
}
void c_closed(const u8 *mem) { of(mem)->events |= EV_CLOSED; }
void c_fail(const u8 *mem, u32 code) { struct sess *x = of(mem); x->events |= EV_FAIL; x->fail_code = (int)code; }

API void h_select(int i)
{
    s = &ss[i];
    if (!s->mem) s->mem = calloc(1, tls_layout[L_SIZE]);
}
API int h_sessions(void) { return NS; }
API u64 h_session_size(void) { return tls_layout[L_SIZE]; }
API int h_start(const char *host, int insecure, u64 now)
{
    s->out_len = s->app_len = 0;
    s->events = s->fail_code = s->refuse_send = 0;
    s->reply_cf = -1;
    K5(tls_start, P(s->mem), P(host), P(host_send), P(host_ops), (u64)insecure, now);
    return cf ? -(int)f32(s, L_ERROR) : 0;
}
API void h_set_extra(const void *table) { x509_extra = P(table); }
API int h_verified(void) { return (int)f32(s, L_VERIFIED); }
API int h_sigalg_checked(void) { return s->mem[tls_layout[L_HAVE_KEY]]; }
API int h_cert_err(void) { return (int)f32(s, L_CERT_ERR); }
API int h_depth(void) { return (int)f32(s, L_DEPTH); }
API const char *h_anchor(void) { return *(const char **)(s->mem + tls_layout[L_ANCHOR]); }
API void h_reply_on_ready(const char *p, size_t n)
{
    free(s->reply);
    s->reply = NULL;
    if (p) { s->reply = malloc(n); memcpy(s->reply, p, n); s->reply_len = n; }
}
API int h_reply_cf(void) { return s->reply_cf; }
API void h_input(const u8 *p, size_t n) { K(tls_input, P(s->mem), P(p), n); }
API int h_write(const u8 *p, size_t n) { K(tls_write, P(s->mem), P(p), n); return cf; }
API void h_close(void) { K(tls_close, P(s->mem), 0, 0); }
API void h_abort(void) { K(tls_abort, P(s->mem), 0, 0); }
API void h_refuse_send(int on) { s->refuse_send = on; }
API size_t h_out_len(void) { return s->out_len; }
API size_t h_take_out(u8 *dst, size_t max) { return take(&s->out, &s->out_len, dst, max); }
API size_t h_app_len(void) { return s->app_len; }
API size_t h_take_app(u8 *dst, size_t max) { return take(&s->app, &s->app_len, dst, max); }
API int h_events(void) { return s->events; }
API int h_fail_code(void) { return s->fail_code; }
API int h_state(void) { return (int)f32(s, L_STATE); }
API int h_alert(void) { return (int)f32(s, L_ALERT); }
API void h_info(int *certs, int *bytes, int *sigalg)
{
    *certs = (int)f32(s, L_CERTS); *bytes = (int)f32(s, L_CERT_BYTES); *sigalg = (int)f32(s, L_SIGALG);
}
const char *tl_text(int code, const u8 *mem);     /* shim.asm */
API const char *h_error_text(int code) { return tl_text(code, s->mem); }
