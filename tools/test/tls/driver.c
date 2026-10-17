/*
 * driver.c - host tests for the TLS crypto (src/kernel/sha256.asm,
 * aesgcm.asm, x25519.asm), linked with shim.obj.
 *
 *   tls_test.exe FILE
 *
 * FILE (made by tools/test/tls/run.py) holds the published vectors and
 * random cases from independent references, one per line:
 *   sha MSG DIGEST                 sharep BYTE COUNT DIGEST
 *   hmac KEY MSG MAC               hkdf SALT IKM INFO L PRK OKM
 *   label SECRET LABEL CTX L OUT   gcm KEY IV AAD PT CT TAG
 *   x25519 K U OUT                 x25519base K OUT
 *   x25519iter N OUT               (k = u = 9, then k, u = X25519(k, u), k)
 * hex, '-' for empty. Every case runs with its buffers at odd addresses
 * inside canary bytes or ending at a no-access page (alternating lines);
 * SHA and HMAC both in one call and fed in uneven pieces; AES-GCM sealed,
 * opened, and opened again with one bit flipped in the tag, the ciphertext
 * and the additional data. The whole file runs with plain-x86 SHA-256 and
 * again with SHA-NI when the CPU has it.
 * Then register preservation: entry points through kcall with every GPR and
 * XMM0-15 loaded with patterns, RSP 16- and 8-byte aligned at entry; every
 * GPR but RAX, RSP and the XMM registers the module does not claim must come
 * back unchanged. Last, a rough speed for each.
 * Exit status 0 only if everything passed.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cpuid.h>
#include <windows.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

extern char sha256_init[], sha256_update[], sha256_final[], sha256[];
extern char hmac_init[], hmac_update[], hmac_final[], hmac_sha256[];
extern char hkdf_extract[], hkdf_expand[], tls13_expand_label[];
extern char gcm_supported[], gcm_init[], gcm_seal[], gcm_open[];
extern char x25519[], x25519_base[];
extern u8 sha256_mode, gcm_mode;

u64 kc(void *target, const u64 *args, int *cf);

typedef struct {
    u64 gpr[16];        /* rax rcx rdx rbx rsp rbp rsi rdi r8..r15 */
    u8 xmm[16][16];
} regs_t;
void kcall(void *target, regs_t *in, regs_t *out, int misalign);

enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };
static const char *gpr_name[16] = {
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };

#define SHA_CTX  112
#define HMAC_CTX 224
#define GCM_CTX  320

/* call a kernel function, arguments in RDI, RSI, RDX, RCX, R8, R9 order */
static int last_cf;
#define P(x) ((u64)(uintptr_t)(x))
static u64 K(void *fn, u64 rdi, u64 rsi, u64 rdx, u64 rcx, u64 r8, u64 r9)
{
    u64 a[6] = { rdi, rsi, rdx, rcx, r8, r9 };
    return kc(fn, a, &last_cf);
}

/* ---- helpers ------------------------------------------------------------- */

static int passes, fails;

static size_t unhex(const char *s, u8 *out)
{
    size_t n = 0;
    int hi = -1;
    if (!strcmp(s, "-")) return 0;
    for (; *s; s++) {
        int c = *s, v;
        if (c >= '0' && c <= '9') v = c - '0';
        else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
        else continue;
        if (hi < 0) hi = v;
        else { out[n++] = (u8)(hi << 4 | v); hi = -1; }
    }
    return n;
}

static void hexstr(const u8 *p, size_t n, char *out)
{
    for (size_t i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", p[i]);
    out[2 * n] = 0;
}

static void result(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (ok) passes++; else fails++;
}

/* Buffer placement. PLACE_ODD: an odd address with 32 canary bytes on each
 * side. PLACE_END: the buffer ends where a PAGE_NOACCESS page begins. */
enum { PLACE_ODD, PLACE_END };
#define CANARY 0xA5
#define MAXBUF 32
static int place_mode;
static struct { u8 *base, *p; size_t n, size; int mode; } bufs[MAXBUF];
static int nbufs;

static u8 *place(const u8 *src, size_t n)
{
    if (nbufs == MAXBUF) { fprintf(stderr, "too many buffers\n"); exit(2); }
    u8 *base, *p;
    size_t size;
    if (place_mode == PLACE_ODD) {
        size = n + 96;
        base = malloc(size);
        memset(base, CANARY, size);
        p = (u8 *)(((uintptr_t)base + 15) & ~(uintptr_t)15) + 33;
    } else {
        size_t pages = n ? (n + 4095) / 4096 : 1;
        size = (pages + 1) * 4096;
        base = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        DWORD old;
        if (!base || !VirtualProtect(base + pages * 4096, 4096, PAGE_NOACCESS, &old)) {
            fprintf(stderr, "VirtualAlloc failed\n");
            exit(2);
        }
        memset(base, CANARY, pages * 4096);
        p = base + pages * 4096 - n;
    }
    if (src) memcpy(p, src, n);
    else memset(p, 0xCC, n);
    bufs[nbufs].base = base;
    bufs[nbufs].p = p;
    bufs[nbufs].n = n;
    bufs[nbufs].size = size;
    bufs[nbufs].mode = place_mode;
    nbufs++;
    return p;
}

/* canaries intact around every buffer placed so far? */
static int guards_ok(void)
{
    for (int i = 0; i < nbufs; i++) {
        u8 *q = bufs[i].base, *end;
        if (bufs[i].mode == PLACE_ODD) end = q + bufs[i].size;
        else end = bufs[i].p + bufs[i].n;     /* the rest faults on its own */
        for (; q < end; q++) {
            if (q >= bufs[i].p && q < bufs[i].p + bufs[i].n) continue;
            if (*q != CANARY) return 0;
        }
    }
    return 1;
}

static void release(void)
{
    for (int i = 0; i < nbufs; i++) {
        if (bufs[i].mode == PLACE_ODD) free(bufs[i].base);
        else VirtualFree(bufs[i].base, 0, MEM_RELEASE);
    }
    nbufs = 0;
}

/* ---- the cases ------------------------------------------------------------ */

static u32 rng = 12345;
static u32 rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }

/* feed data to an update function in uneven pieces */
static void feed(void *update, u8 *ctx, const u8 *d, size_t n)
{
    while (n) {
        size_t k = rnd() % 4 ? rnd() % 70 : rnd() % 300;
        if (k > n) k = n;
        K(update, P(ctx), P(d), k, 0, 0, 0);
        d += k;
        n -= k;
    }
}

static int bad_lines;
static void mismatch(int line, const char *what, const u8 *got, const u8 *want, size_t n)
{
    if (bad_lines++ >= 12) return;
    char *g = malloc(2 * n + 1), *w = malloc(2 * n + 1);
    hexstr(got, n, g);
    hexstr(want, n, w);
    printf("      line %d, %s:\n        got  %.200s\n        want %.200s\n", line, what, g, w);
    free(g);
    free(w);
}

#define CHECK(what, got, want, n) do { \
    if (memcmp((got), (want), (n))) { mismatch(line, what, got, want, n); ok = 0; } } while (0)

static u8 hA[1 << 16], hB[1 << 16], hC[1 << 16], hD[1 << 16], hE[1 << 16];

static int one_case(int line, char **v, int *counts)
{
    int ok = 1;
    const char *op = v[0];
    if (!strcmp(op, "sha") || !strcmp(op, "sharep")) {
        size_t n;
        u8 *msg;
        if (op[3]) {                                    /* sharep BYTE COUNT DIGEST */
            n = strtoul(v[2], 0, 10);
            msg = malloc(n ? n : 1);
            memset(msg, (int)strtoul(v[1], 0, 16), n);
            unhex(v[3], hB);
        } else {
            n = unhex(v[1], hA);
            msg = malloc(n ? n : 1);
            memcpy(msg, hA, n);
            unhex(v[2], hB);
        }
        u8 *m = place(msg, n), *d = place(NULL, 32), *ctx = place(NULL, SHA_CTX);
        free(msg);
        K(sha256, P(d), P(m), n, 0, 0, 0);
        CHECK("sha256", d, hB, 32);
        memset(d, 0, 32);
        K(sha256_init, P(ctx), 0, 0, 0, 0, 0);
        feed(sha256_update, ctx, m, n);
        K(sha256_final, P(ctx), P(d), 0, 0, 0, 0);
        CHECK("sha256 in pieces", d, hB, 32);
        counts[0]++;
    } else if (!strcmp(op, "hmac")) {
        size_t kn = unhex(v[1], hA), mn = unhex(v[2], hB);
        unhex(v[3], hC);
        u8 *k = place(hA, kn), *m = place(hB, mn), *d = place(NULL, 32);
        u8 *ctx = place(NULL, HMAC_CTX);
        K(hmac_sha256, P(d), P(k), kn, P(m), mn, 0);
        CHECK("hmac_sha256", d, hC, 32);
        memset(d, 0, 32);
        K(hmac_init, P(ctx), P(k), kn, 0, 0, 0);
        feed(hmac_update, ctx, m, mn);
        K(hmac_final, P(ctx), P(d), 0, 0, 0, 0);
        CHECK("hmac in pieces", d, hC, 32);
        counts[1]++;
    } else if (!strcmp(op, "hkdf")) {
        size_t sn = unhex(v[1], hA), in = unhex(v[2], hB), fn = unhex(v[3], hC);
        size_t L = strtoul(v[4], 0, 10);
        unhex(v[5], hD);
        unhex(v[6], hE);
        u8 *s = place(hA, sn), *i = place(hB, in), *f = place(hC, fn);
        u8 *prk = place(NULL, 32), *okm = place(NULL, L);
        K(hkdf_extract, P(prk), P(s), sn, P(i), in, 0);
        CHECK("hkdf_extract", prk, hD, 32);
        K(hkdf_expand, P(okm), P(prk), P(f), fn, L, 0);
        CHECK("hkdf_expand", okm, hE, L);
        counts[2]++;
    } else if (!strcmp(op, "label")) {
        unhex(v[1], hA);
        size_t ln = unhex(v[2], hB), cn = unhex(v[3], hC), L = strtoul(v[4], 0, 10);
        hB[ln] = 0;
        unhex(v[5], hD);
        u8 *sec = place(hA, 32), *lab = place(hB, ln + 1), *c = place(hC, cn);
        u8 *out = place(NULL, L);
        K(tls13_expand_label, P(out), P(sec), P(lab), P(c), cn, L);
        CHECK("tls13_expand_label", out, hD, L);
        counts[3]++;
    } else if (!strcmp(op, "gcm")) {
        unhex(v[1], hA);
        unhex(v[2], hB);
        size_t an = unhex(v[3], hC), n = unhex(v[4], hD);
        unhex(v[5], hE);
        unhex(v[6], hE + n);
        u8 *key = place(hA, 16), *iv = place(hB, 12), *aad = place(hC, an);
        u8 *ctx = place(NULL, GCM_CTX), *buf = place(hD, n + 16);
        K(gcm_init, P(ctx), P(key), 0, 0, 0, 0);
        K(gcm_seal, P(ctx), P(iv), P(aad), an, P(buf), n);
        CHECK("gcm_seal", buf, hE, n + 16);
        memcpy(buf, hE, n + 16);
        K(gcm_open, P(ctx), P(iv), P(aad), an, P(buf), n);
        if (last_cf) { printf("      line %d: gcm_open rejected a good record\n", line); ok = 0; }
        CHECK("gcm_open", buf, hD, n);
        /* one flipped bit anywhere: rejected, and the record left as it was */
        for (int t = 0; t < 3; t++) {
            u8 *flip;
            const char *where;
            memcpy(buf, hE, n + 16);
            if (t == 0) { flip = buf + n + rnd() % 16; where = "tag"; }
            else if (t == 1 && n) { flip = buf + rnd() % n; where = "ciphertext"; }
            else if (t == 2 && an) { flip = aad + rnd() % an; where = "additional data"; }
            else continue;
            u8 bit = (u8)(1 << rnd() % 8);
            *flip ^= bit;
            K(gcm_open, P(ctx), P(iv), P(aad), an, P(buf), n);
            int cf = last_cf;
            *flip ^= bit;
            if (!cf || memcmp(buf, hE, n + 16)) {
                printf("      line %d: a flipped bit in the %s was %s\n", line, where,
                       !cf ? "accepted" : "rejected, but the record changed");
                ok = 0;
            }
        }
        counts[4]++;
    } else if (!strcmp(op, "x25519") || !strcmp(op, "x25519base")) {
        int base = op[6] != 0;
        unhex(v[1], hA);
        unhex(v[2], hB);
        if (!base) unhex(v[3], hC);
        u8 *k = place(hA, 32), *out = place(NULL, 32);
        if (base) {
            K(x25519_base, P(out), P(k), 0, 0, 0, 0);
            CHECK("x25519_base", out, hB, 32);
        } else {
            u8 *u = place(hB, 32);
            K(x25519, P(out), P(k), P(u), 0, 0, 0);
            CHECK("x25519", out, hC, 32);
            if (memcmp(k, hA, 32) || memcmp(u, hB, 32)) {
                printf("      line %d: x25519 changed its inputs\n", line);
                ok = 0;
            }
        }
        counts[5]++;
    } else if (!strcmp(op, "x25519iter")) {
        int n = atoi(v[1]);
        unhex(v[2], hC);
        u8 k[32] = { 9 }, u[32] = { 9 }, r[32];
        for (int i = 0; i < n; i++) {
            K(x25519, P(r), P(k), P(u), 0, 0, 0);
            memcpy(u, k, 32);
            memcpy(k, r, 32);
        }
        CHECK("x25519 iterated", k, hC, 32);
        counts[5]++;
    } else {
        printf("      line %d: unknown case '%s'\n", line, op);
        return 0;
    }
    if (!guards_ok()) {
        printf("      line %d: %s wrote outside its buffers\n", line, op);
        ok = 0;
    }
    release();
    return ok;
}

static void run_file(const char *path, const char *mode)
{
    FILE *f = fopen(path, "r");
    if (!f) { result(0, "cannot open %s", path); return; }
    static char buf[1 << 18];
    int line = 0, bad = 0, counts[6] = { 0 };
    bad_lines = 0;
    while (fgets(buf, sizeof buf, f)) {
        line++;
        char *v[8];
        int n = 0;
        for (char *t = strtok(buf, " \r\n"); t && n < 8; t = strtok(NULL, " \r\n"))
            v[n++] = t;
        if (!n || v[0][0] == '#') continue;
        place_mode = (line & 1) ? PLACE_ODD : PLACE_END;
        if (!one_case(line, v, counts)) bad++;
    }
    fclose(f);
    result(bad == 0, "%s: %d sha256, %d hmac, %d hkdf, %d expand_label, %d gcm, %d x25519 "
           "cases; %d failed", mode, counts[0], counts[1], counts[2], counts[3], counts[4],
           counts[5], bad);
}

/* ---- register preservation through kcall --------------------------------- */

#define NA (~0ull)      /* argument left as the pattern */

static void kcall_case(const char *name, void *fn, int keep_xmm_from, const u64 *args,
                       const u8 *out, const char *exphex, int misalign)
{
    regs_t in, o;
    static const int argreg[6] = { RDI, RSI, RDX, RCX, R8, R9 };
    char problems[512] = "";
    size_t pl = 0;
    for (int i = 0; i < 16; i++)
        in.gpr[i] = 0xF00DFACE00000000ull ^ ((u64)(i + 1) * 0x0101010101010101ull)
                  ^ ((u64)misalign << 60);
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++)
            in.xmm[i][j] = (u8)(0x37 * i + 0x11 * j + 0x5A);
    for (int i = 0; i < 6; i++)
        if (args[i] != NA) in.gpr[argreg[i]] = args[i];
    kcall(fn, &in, &o, misalign);
    for (int r = 0; r < 16; r++) {
        if (r == RAX || r == RSP) continue;
        if (o.gpr[r] != in.gpr[r])
            pl += snprintf(problems + pl, sizeof problems - pl, " %s changed;", gpr_name[r]);
    }
    if (o.gpr[RSP] != 0)
        pl += snprintf(problems + pl, sizeof problems - pl, " rsp moved by %lld;",
                       (long long)o.gpr[RSP]);
    for (int x = keep_xmm_from; x < 16; x++)
        if (memcmp(o.xmm[x], in.xmm[x], 16))
            pl += snprintf(problems + pl, sizeof problems - pl, " xmm%d changed;", x);
    if (out && exphex) {
        u8 exp[64];
        size_t n = unhex(exphex, exp);
        if (memcmp(out, exp, n))
            pl += snprintf(problems + pl, sizeof problems - pl, " output wrong;");
    }
    result(pl == 0, "registers: %-20s modes %d/%d, entry RSP %s%s", name, sha256_mode, gcm_mode,
           misalign ? "= 0 mod 16" : "= 8 mod 16", problems);
}

static void registers(int have_gcm)
{
    static u8 ctx[GCM_CTX], hctx[256], out[64], gbuf[64];
    static const u8 abc[3] = { 'a', 'b', 'c' };
    static u8 key[16], iv[12], k25[32] = { 9 }, u25[32] = { 9 };
    const char *abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const char *x_one = "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079";
    for (int m = 0; m < 2; m++) {
        memset(out, 0, sizeof out);
        u64 a1[6] = { P(out), P(abc), 3, NA, NA, NA };
        kcall_case("sha256", sha256, 11, a1, out, abc_sha, m);
        u64 a2[6] = { P(ctx), NA, NA, NA, NA, NA };
        kcall_case("sha256_init", sha256_init, 11, a2, 0, 0, m);
        u64 a3[6] = { P(ctx), P(abc), 3, NA, NA, NA };
        kcall_case("sha256_update", sha256_update, 11, a3, 0, 0, m);
        memset(out, 0, sizeof out);
        u64 a4[6] = { P(ctx), P(out), NA, NA, NA, NA };
        kcall_case("sha256_final", sha256_final, 11, a4, out, abc_sha, m);
        u64 a5[6] = { P(out), P(abc), 3, P(abc), 3, NA };
        kcall_case("hmac_sha256", hmac_sha256, 11, a5, 0, 0, m);
        u64 a6[6] = { P(hctx), P(abc), 3, NA, NA, NA };
        kcall_case("hmac_init", hmac_init, 11, a6, 0, 0, m);
        kcall_case("hmac_update", hmac_update, 11, a6, 0, 0, m);
        u64 a7[6] = { P(hctx), P(out), NA, NA, NA, NA };
        kcall_case("hmac_final", hmac_final, 11, a7, 0, 0, m);
        u64 a8[6] = { P(out), P(abc), 3, P(abc), 3, NA };
        kcall_case("hkdf_extract", hkdf_extract, 11, a8, 0, 0, m);
        u64 a9[6] = { P(out), P(out + 32), P(abc), 3, 42, NA };
        kcall_case("hkdf_expand", hkdf_expand, 11, a9, 0, 0, m);
        u64 a10[6] = { P(out), P(out + 32), P("derived"), P(abc), 3, 32 };
        kcall_case("tls13_expand_label", tls13_expand_label, 11, a10, 0, 0, m);
        if (have_gcm) {
            u64 b1[6] = { P(ctx), P(key), NA, NA, NA, NA };
            kcall_case("gcm_init", gcm_init, 10, b1, 0, 0, m);
            memset(gbuf, 0, sizeof gbuf);
            u64 b2[6] = { P(ctx), P(iv), P(abc), 0, P(gbuf), 0 };
            kcall_case("gcm_seal", gcm_seal, 10, b2, gbuf, "58e2fccefa7e3061367f1d57a4e7455a", m);
            kcall_case("gcm_open", gcm_open, 10, b2, 0, 0, m);
            u64 b3[6] = { P(ctx), P(iv), P(abc), 3, P(gbuf), 16 };
            kcall_case("gcm_seal 16", gcm_seal, 10, b3, 0, 0, m);
            static u8 gbig[300 + 16];
            u64 b4[6] = { P(ctx), P(iv), P(gbig), 200, P(gbig), 300 };
            kcall_case("gcm_seal 300", gcm_seal, 10, b4, 0, 0, m);
            kcall_case("gcm_open 300", gcm_open, 10, b4, 0, 0, m);
        }
        u64 c1[6] = { P(out), P(k25), P(u25), NA, NA, NA };
        kcall_case("x25519", x25519, 0, c1, out, x_one, m);
        u64 c2[6] = { P(out), P(k25), NA, NA, NA, NA };
        kcall_case("x25519_base", x25519_base, 0, c2, out, x_one, m);
    }
}

static double now(void)
{
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return (double)t.QuadPart / (double)f.QuadPart;
}

static void speed(int have_gcm, int ladders)
{
    static u8 big[1 << 20], d[32], ctx[GCM_CTX], key[16], iv[12];
    static u8 k[32] = { 1 }, u[32] = { 9 };
    double t = now();
    for (int i = 0; i < 16; i++) K(sha256, P(d), P(big), sizeof big - 16, 0, 0, 0);
    t = now() - t;
    printf("      sha256 (mode %d): %.0f MB/s\n", sha256_mode, 16.0 / t);
    if (have_gcm) {
        K(gcm_init, P(ctx), P(key), 0, 0, 0, 0);
        t = now();
        for (int i = 0; i < 16; i++) K(gcm_seal, P(ctx), P(iv), 0, 0, P(big), sizeof big - 16);
        t = now() - t;
        printf("      aes-128-gcm seal (mode %d): %.0f MB/s\n", gcm_mode, 16.0 / t);
    }
    if (ladders) {
        t = now();
        for (int i = 0; i < 100; i++) K(x25519, P(d), P(k), P(u), 0, 0, 0);
        t = now() - t;
        printf("      x25519: %.0f us each\n", t / 100 * 1e6);
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: tls_test FILE\n"); return 2; }
    unsigned a = 0, b = 0, c = 0, d = 0;
    __get_cpuid_count(7, 0, &a, &b, &c, &d);
    int have_ni = (b >> 29) & 1;
    int have_vaes = ((b >> 5) & 1) && ((c >> 9) & 3) == 3;   /* AVX2, VAES, VPCLMULQDQ */
    K(gcm_supported, 0, 0, 0, 0, 0, 0);
    int have_gcm = !last_cf;
    if (!have_gcm) result(0, "this CPU lacks AES-NI, PCLMULQDQ or SSSE3: AES-GCM untested");

    int fast = have_ni || have_vaes;

    printf("-- vectors and random cases\n");
    sha256_mode = 1;
    gcm_mode = 1;
    run_file(argv[1], "plain x86 SHA-256, AES-NI GCM");
    if (fast) {
        sha256_mode = have_ni ? 2 : 1;
        gcm_mode = have_vaes ? 2 : 1;
        run_file(argv[1], have_vaes ? "SHA-NI SHA-256, VAES GCM" : "SHA-NI SHA-256");
    }
    if (!have_ni) printf("      (no SHA-NI on this CPU: only plain x86 SHA-256 tested)\n");
    if (!have_vaes) printf("      (no VAES on this CPU: only AES-NI GCM tested)\n");

    printf("-- register preservation (kernel convention)\n");
    sha256_mode = 1;
    gcm_mode = 1;
    registers(have_gcm);
    if (fast) { sha256_mode = have_ni ? 2 : 1; gcm_mode = have_vaes ? 2 : 1; registers(have_gcm); }

    printf("-- speed\n");
    sha256_mode = 1;
    gcm_mode = 1;
    speed(have_gcm, 1);
    if (fast) { sha256_mode = have_ni ? 2 : 1; gcm_mode = have_vaes ? 2 : 1; speed(have_gcm, 0); }

    printf("-- %d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
