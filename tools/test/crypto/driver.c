/*
 * driver.c - host tests for src/kernel/crypto.asm, linked with shim.obj.
 *
 *   crypto_test.exe [--vectors FILE]
 *
 * 1. Known-answer vectors (FIPS-197 C.1, RFC 4493 section 4, Bluetooth Core
 *    Vol 3 Part H Appendix D as in Linux net/bluetooth/smp.c) through the
 *    Windows ABI wrappers, twice: with every buffer at an odd address inside
 *    canary bytes, and with every buffer ending at a no-access page (so any
 *    read or write past the end faults).
 * 2. crypto_selftest.
 * 3. Register preservation: every entry point called through kcall with all
 *    GPRs and XMM0-15 loaded with patterns (partial-width arguments carry
 *    junk in their upper bits), RSP 16- and 8-byte aligned at entry; every
 *    GPR but RAX, RSP itself and XMM6-15 must come back unchanged.
 * 4. Random AES and AES-CMAC cases from FILE (made by run.py from an
 *    independent implementation).
 * Exit status 0 only if everything passed.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

/* Windows ABI wrappers (shim.asm) */
void w_aes_encrypt(const u8 *key, u8 *block);
void w_aes_cmac(const u8 *key, const u8 *msg, u32 len, u8 *tag);
void w_smp_e(const u8 *key, u8 *block);
void w_smp_ah(const u8 *irk, const u8 *r, u8 *hash);
void w_smp_c1(const u8 *k, const u8 *r, const u8 *preq, const u8 *pres,
              const u8 *ia, const u8 *ra, u8 *out);
void w_smp_s1(const u8 *k, const u8 *r1, const u8 *r2, u8 *out);
void w_smp_f4(const u8 *u, const u8 *v, const u8 *x, u8 z, u8 *out);
void w_smp_f5(const u8 *w, const u8 *n1, const u8 *n2, const u8 *a1,
              const u8 *a2, u8 *mackey, u8 *ltk);
void w_smp_f6(const u8 *w, const u8 *n1, const u8 *n2, const u8 *r,
              const u8 *io_cap, const u8 *a1, const u8 *a2, u8 *out);
u32 w_smp_g2(const u8 *u, const u8 *v, const u8 *x, const u8 *y);
void w_smp_h6(const u8 *w, u32 key_id, u8 *out);
int w_crypto_selftest(void);

/* raw kernel entry points, for kcall */
extern char aes_encrypt[], aes_cmac[], smp_e[], smp_ah[], smp_c1[], smp_s1[];
extern char smp_f4[], smp_f5[], smp_f6[], smp_g2[], smp_h6[], crypto_selftest[];

typedef struct {
    u64 gpr[16];        /* rax rcx rdx rbx rsp rbp rsi rdi r8..r15 */
    u8 xmm[16][16];
} regs_t;
void kcall(void *target, regs_t *in, regs_t *out, int misalign);

enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };
static const char *gpr_name[16] = {
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };

/* ---- vectors (hex; SMP values least significant byte first) ------------- */

#define AES_KEY  "000102030405060708090a0b0c0d0e0f"
#define AES_PT   "00112233445566778899aabbccddeeff"
#define AES_CT   "69c4e0d86a7b0430d8cdb78070b4c55a"
/* smp_e is AES with key, block and result reversed: the same vector LSB first */
#define E_KEY    "0f0e0d0c0b0a09080706050403020100"
#define E_PT     "ffeeddccbbaa99887766554433221100"
#define E_CT     "5ac5b47080b7cdd830047b6ad8e0c469"

#define CMAC_KEY "2b7e151628aed2a6abf7158809cf4f3c"
#define CMAC_MSG "6bc1bee22e409f96e93d7e117393172a" "ae2d8a571e03ac9c9eb76fac45af8e51" \
                 "30c81c46a35ce411e5fbc1191a0a52ef" "f69f2445df4f9b17ad2b417be66c3710"
static const struct { int len; const char *tag; } cmac_kat[4] = {
    { 0,  "bb1d6929e95937287fa37d129b756746" },
    { 16, "070a16b46b4d4144f79bdd9dd04a287c" },
    { 40, "dfa66747de9ae63030ca32611497c827" },
    { 64, "51f0bebf7e3b9d92fc49741779363cfe" },
};

#define AH_IRK   "9b7d390aa610103405adc857a33402ec"
#define AH_R     "948170"
#define AH_EXP   "aafb0d"

#define ZERO16   "00000000000000000000000000000000"
#define C1_R     "e02e70c64e2788630e6fad5621d58357"
#define C1_PREQ  "01010000100707"
#define C1_PRES  "02030000080005"
#define C1_IA    "a6a5a4a3a2a1" "01"   /* BD_ADDR then type: iat = 1 */
#define C1_RA    "b6b5b4b3b2b1" "00"   /* rat = 0 */
#define C1_EXP   "863bf1bec54da7d2ea888987ef3f1e1e"

#define S1_R1    "88776655443322110000000000000000"
#define S1_R2    "00ffeeddccbbaa990000000000000000"
#define S1_EXP   "62a06d79ae16425b9bf4b0e8f0e11f9a"

#define F4_U     "e69d350e480103ccdbfdf4ac1191f4ef" "b9a5f9e9a7832c5e2cbe97f2d203b020"
#define F4_V     "fdc57ff449dd4f6bfb7c9df1c29acb59" "2ae7d4eefbfc0a909abbf6323d8b1855"
#define F4_X     "abae2b71ecb2ffff3e7377d15484cbd5"
#define F4_EXP   "2d8774a9bea1edf11cbda907f116c9f2"

#define F5_W     "98a6bf73f3348d86f166f8b4136b7999" "9b7d390aa610103405adc857a33402ec"
#define F5_N1    "abae2b71ecb2ffff3e7377d15484cbd5"
#define F5_N2    "cfc43dfff78365216e5fa725cce7e8a6"
#define F5_A1    "cebf3737125600"
#define F5_A2    "c1cf2d7013a700"
#define F5_MACKEY "206e63ce206a3ffd024a08a176f16529"
#define F5_LTK   "380a7594b522059823cdd76911798669"

#define F6_W     F5_MACKEY
#define F6_R     "c80f2d0cd242da0854bb53b43b34a312"
#define F6_IOCAP "020101"
#define F6_EXP   "618f95da090b6cd2c5e8d09c9873c4e3"

#define G2_Y     F5_N2
#define G2_EXP   (0x2f9ed5bau % 1000000u)

#define H6_W     "9b7d390aa610103405adc857a33402ec"
#define H6_KEYID 0x6c656272u           /* 'lebr', bytes 72 62 65 6c */
#define H6_EXP   "9963b180e2a9d3e81cc96de702e19a2d"

/* ---- helpers ------------------------------------------------------------- */

static int passes, fails;

static size_t unhex(const char *s, u8 *out)
{
    size_t n = 0;
    int hi = -1;
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

static u8 *placehex(const char *hex)
{
    u8 tmp[512];
    size_t n = unhex(hex, tmp);
    return place(tmp, n);
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

/* compare a result buffer with a hex string; also checks canaries */
static void expect(const char *what, const u8 *got, const char *exphex)
{
    u8 exp[64];
    char g[130], e[130];
    size_t n = unhex(exphex, exp);
    int same = memcmp(got, exp, n) == 0;
    int guards = guards_ok();
    if (same && guards) { result(1, "%s", what); return; }
    hexstr(got, n, g);
    hexstr(exp, n, e);
    if (!same) result(0, "%s: got %s want %s", what, g, e);
    else result(0, "%s: wrote outside its buffers", what);
}

/* ---- 1. vectors through the ABI wrappers --------------------------------- */

static void vectors(int mode)
{
    const char *m = mode == PLACE_ODD ? "odd addresses" : "page ends";
    char what[96];
    place_mode = mode;

    { u8 *k = placehex(AES_KEY), *b = placehex(AES_PT);
      w_aes_encrypt(k, b);
      snprintf(what, sizeof what, "aes_encrypt FIPS-197 C.1 (%s)", m);
      expect(what, b, AES_CT); release(); }

    { u8 *k = placehex(AES_KEY), *ref = placehex(AES_KEY), *b = placehex(AES_KEY);
      w_aes_encrypt(k, ref);                  /* E(K, K) with separate buffers */
      w_aes_encrypt(b, b);                    /* ... and with key == block */
      char hx[33]; hexstr(ref, 16, hx);
      snprintf(what, sizeof what, "aes_encrypt with the key aliasing the block (%s)", m);
      expect(what, b, hx); release(); }

    { u8 *k = placehex(E_KEY), *b = placehex(E_PT);
      w_smp_e(k, b);
      snprintf(what, sizeof what, "smp_e FIPS-197 C.1 reversed (%s)", m);
      expect(what, b, E_CT); release(); }

    for (int i = 0; i < 4; i++) {
        u8 msg[64];
        unhex(CMAC_MSG, msg);
        u8 *k = placehex(CMAC_KEY), *mm = place(msg, cmac_kat[i].len), *t = place(NULL, 16);
        w_aes_cmac(k, mm, cmac_kat[i].len, t);
        snprintf(what, sizeof what, "aes_cmac RFC 4493 example %d, %d bytes (%s)",
                 i + 1, cmac_kat[i].len, m);
        expect(what, t, cmac_kat[i].tag);
        release();
    }

    { u8 *irk = placehex(AH_IRK), *r = placehex(AH_R), *h = place(NULL, 3);
      w_smp_ah(irk, r, h);
      snprintf(what, sizeof what, "smp_ah (%s)", m);
      expect(what, h, AH_EXP); release(); }

    { u8 *k = placehex(ZERO16), *r = placehex(C1_R), *preq = placehex(C1_PREQ),
         *pres = placehex(C1_PRES), *ia = placehex(C1_IA), *ra = placehex(C1_RA),
         *o = place(NULL, 16);
      w_smp_c1(k, r, preq, pres, ia, ra, o);
      snprintf(what, sizeof what, "smp_c1 (%s)", m);
      expect(what, o, C1_EXP); release(); }

    { u8 *k = placehex(ZERO16), *r1 = placehex(S1_R1), *r2 = placehex(S1_R2),
         *o = place(NULL, 16);
      w_smp_s1(k, r1, r2, o);
      snprintf(what, sizeof what, "smp_s1 (%s)", m);
      expect(what, o, S1_EXP); release(); }

    { u8 *u = placehex(F4_U), *v = placehex(F4_V), *x = placehex(F4_X), *o = place(NULL, 16);
      w_smp_f4(u, v, x, 0x00, o);
      snprintf(what, sizeof what, "smp_f4 (%s)", m);
      expect(what, o, F4_EXP); release(); }

    { u8 *w = placehex(F5_W), *n1 = placehex(F5_N1), *n2 = placehex(F5_N2),
         *a1 = placehex(F5_A1), *a2 = placehex(F5_A2), *mk = place(NULL, 16),
         *ltk = place(NULL, 16);
      w_smp_f5(w, n1, n2, a1, a2, mk, ltk);
      snprintf(what, sizeof what, "smp_f5 mackey (%s)", m);
      expect(what, mk, F5_MACKEY);
      snprintf(what, sizeof what, "smp_f5 ltk (%s)", m);
      expect(what, ltk, F5_LTK); release(); }

    { u8 *w = placehex(F6_W), *n1 = placehex(F5_N1), *n2 = placehex(F5_N2),
         *r = placehex(F6_R), *io = placehex(F6_IOCAP), *a1 = placehex(F5_A1),
         *a2 = placehex(F5_A2), *o = place(NULL, 16);
      w_smp_f6(w, n1, n2, r, io, a1, a2, o);
      snprintf(what, sizeof what, "smp_f6 (%s)", m);
      expect(what, o, F6_EXP); release(); }

    { u8 *u = placehex(F4_U), *v = placehex(F4_V), *x = placehex(F4_X), *y = placehex(G2_Y);
      u32 val = w_smp_g2(u, v, x, y);
      int ok = val == G2_EXP && guards_ok();
      result(ok, "smp_g2 = %06u, want %06u (%s)", val, G2_EXP, m); release(); }

    { u8 *w = placehex(H6_W), *o = place(NULL, 16);
      w_smp_h6(w, H6_KEYID, o);
      snprintf(what, sizeof what, "smp_h6 (%s)", m);
      expect(what, o, H6_EXP); release(); }
}

/* ---- 3. register preservation through kcall ----------------------------- */

enum { K_END, K_BUF, K_IMM8, K_IMM32 };
typedef struct {
    int kind, reg;
    const char *in;     /* K_BUF: initial contents (NULL: an output, 16 or n bytes) */
    const char *exp;    /* K_BUF: expected contents afterwards, or NULL */
    int len;            /* K_BUF: bytes to place, or -1 for all of in (16 if in is NULL) */
    u32 imm;            /* K_IMM*: the value in the low bits */
} karg_t;
typedef struct {
    const char *name;
    void *fn;
    karg_t a[9];
    int check_eax;
    u32 eax;
} kcase_t;

#define BUF(r, i, e)        { K_BUF, r, i, e, -1, 0 }
#define BUFN(r, i, e, n)    { K_BUF, r, i, e, n, 0 }
#define IMM8(r, v)          { K_IMM8, r, 0, 0, 0, v }
#define IMM32(r, v)         { K_IMM32, r, 0, 0, 0, v }

static const kcase_t kcases[] = {
    { "aes_encrypt", aes_encrypt, { BUF(RSI, AES_KEY, 0), BUF(RDI, AES_PT, AES_CT) } },
    { "aes_cmac 0", aes_cmac, { BUF(RSI, CMAC_KEY, 0), BUFN(RDX, CMAC_MSG, 0, 0),
        IMM32(RCX, 0), BUF(RDI, 0, "bb1d6929e95937287fa37d129b756746") } },
    { "aes_cmac 16", aes_cmac, { BUF(RSI, CMAC_KEY, 0), BUFN(RDX, CMAC_MSG, 0, 16),
        IMM32(RCX, 16), BUF(RDI, 0, "070a16b46b4d4144f79bdd9dd04a287c") } },
    { "aes_cmac 40", aes_cmac, { BUF(RSI, CMAC_KEY, 0), BUFN(RDX, CMAC_MSG, 0, 40),
        IMM32(RCX, 40), BUF(RDI, 0, "dfa66747de9ae63030ca32611497c827") } },
    { "aes_cmac 64", aes_cmac, { BUF(RSI, CMAC_KEY, 0), BUFN(RDX, CMAC_MSG, 0, 64),
        IMM32(RCX, 64), BUF(RDI, 0, "51f0bebf7e3b9d92fc49741779363cfe") } },
    { "smp_e", smp_e, { BUF(RSI, E_KEY, 0), BUF(RDI, E_PT, E_CT) } },
    { "smp_ah", smp_ah, { BUF(RSI, AH_IRK, 0), BUF(RDX, AH_R, 0), BUFN(RDI, 0, AH_EXP, 3) } },
    { "smp_c1", smp_c1, { BUF(RSI, ZERO16, 0), BUF(RDX, C1_R, 0), BUF(RCX, C1_PREQ, 0),
        BUF(R8, C1_PRES, 0), BUF(R9, C1_IA, 0), BUF(R10, C1_RA, 0), BUF(RDI, 0, C1_EXP) } },
    { "smp_s1", smp_s1, { BUF(RSI, ZERO16, 0), BUF(RDX, S1_R1, 0), BUF(RCX, S1_R2, 0),
        BUF(RDI, 0, S1_EXP) } },
    { "smp_f4", smp_f4, { BUF(RSI, F4_U, 0), BUF(RDX, F4_V, 0), BUF(RCX, F4_X, 0),
        IMM8(R8, 0), BUF(RDI, 0, F4_EXP) } },
    { "smp_f5", smp_f5, { BUF(RSI, F5_W, 0), BUF(RDX, F5_N1, 0), BUF(RCX, F5_N2, 0),
        BUF(R8, F5_A1, 0), BUF(R9, F5_A2, 0), BUF(RDI, 0, F5_MACKEY), BUF(R10, 0, F5_LTK) } },
    { "smp_f6", smp_f6, { BUF(RSI, F6_W, 0), BUF(RDX, F5_N1, 0), BUF(RCX, F5_N2, 0),
        BUF(R8, F6_R, 0), BUF(R9, F6_IOCAP, 0), BUF(R10, F5_A1, 0), BUF(R11, F5_A2, 0),
        BUF(RDI, 0, F6_EXP) } },
    { "smp_g2", smp_g2, { BUF(RSI, F4_U, 0), BUF(RDX, F4_V, 0), BUF(RCX, F4_X, 0),
        BUF(R8, G2_Y, 0) }, 1, G2_EXP },
    { "smp_h6", smp_h6, { BUF(RSI, H6_W, 0), IMM32(RDX, H6_KEYID), BUF(RDI, 0, H6_EXP) } },
    { "crypto_selftest", crypto_selftest, { { K_END } }, 1, 0 },
};

static void kcall_case(const kcase_t *c, int misalign)
{
    regs_t in, out;
    u8 *ptr[9] = { 0 };
    char problems[512] = "";
    size_t pl = 0;

    for (int i = 0; i < 16; i++)
        in.gpr[i] = 0xF00DFACE00000000ull ^ ((u64)(i + 1) * 0x0101010101010101ull)
                  ^ ((u64)misalign << 60);
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++)
            in.xmm[i][j] = (u8)(0x37 * i + 0x11 * j + 0x5A);

    place_mode = PLACE_END;
    for (int i = 0; i < 9 && c->a[i].kind != K_END; i++) {
        const karg_t *a = &c->a[i];
        if (a->kind == K_BUF) {
            u8 tmp[512];
            size_t n = a->len >= 0 ? (size_t)a->len : a->in ? unhex(a->in, tmp) : 16;
            if (a->in) unhex(a->in, tmp);
            ptr[i] = place(a->in ? tmp : NULL, n);
            in.gpr[a->reg] = (u64)(uintptr_t)ptr[i];
        } else if (a->kind == K_IMM8) {
            in.gpr[a->reg] = (in.gpr[a->reg] & ~0xFFull) | (a->imm & 0xFF);
        } else {
            in.gpr[a->reg] = (in.gpr[a->reg] & ~0xFFFFFFFFull) | a->imm;
        }
    }

    kcall(c->fn, &in, &out, misalign);

    for (int r = 0; r < 16; r++) {
        if (r == RAX || r == RSP) continue;
        if (out.gpr[r] != in.gpr[r])
            pl += snprintf(problems + pl, sizeof problems - pl, " %s changed;", gpr_name[r]);
    }
    if (out.gpr[RSP] != 0)
        pl += snprintf(problems + pl, sizeof problems - pl, " rsp moved by %lld;",
                       (long long)out.gpr[RSP]);
    for (int x = 6; x < 16; x++)
        if (memcmp(out.xmm[x], in.xmm[x], 16))
            pl += snprintf(problems + pl, sizeof problems - pl, " xmm%d changed;", x);
    if (c->check_eax && (u32)out.gpr[RAX] != c->eax)
        pl += snprintf(problems + pl, sizeof problems - pl, " eax %u, want %u;",
                       (u32)out.gpr[RAX], c->eax);
    for (int i = 0; i < 9 && c->a[i].kind != K_END; i++) {
        const karg_t *a = &c->a[i];
        if (a->kind != K_BUF || !a->exp) continue;
        u8 exp[64];
        size_t n = unhex(a->exp, exp);
        if (memcmp(ptr[i], exp, n))
            pl += snprintf(problems + pl, sizeof problems - pl, " %s output wrong;",
                           gpr_name[a->reg]);
    }
    if (!guards_ok())
        pl += snprintf(problems + pl, sizeof problems - pl, " wrote outside a buffer;");
    release();
    result(pl == 0, "registers: %-16s entry RSP %s%s", c->name,
           misalign ? "= 0 mod 16" : "= 8 mod 16", problems);
}

/* ---- 4. random cases from run.py ----------------------------------------- */

static void random_cases(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { result(0, "cannot open %s", path); return; }
    static char line[8192];
    int n_aes = 0, n_cmac = 0, bad = 0, idx = 0;
    while (fgets(line, sizeof line, f)) {
        char kind[16], khex[64], mhex[4096], ehex[64];
        if (sscanf(line, "%15s %63s %4095s %63s", kind, khex, mhex, ehex) != 4) continue;
        u8 key[16], msg[2048], exp[16];
        unhex(khex, key);
        size_t mlen = strcmp(mhex, "-") ? unhex(mhex, msg) : 0;
        unhex(ehex, exp);
        place_mode = (idx++ & 1) ? PLACE_END : PLACE_ODD;
        u8 *k = place(key, 16), *got;
        if (!strcmp(kind, "aes")) {
            got = place(msg, 16);
            w_aes_encrypt(k, got);
            n_aes++;
        } else {
            u8 *mm = place(msg, mlen);
            got = place(NULL, 16);
            w_aes_cmac(k, mm, (u32)mlen, got);
            n_cmac++;
        }
        if (memcmp(got, exp, 16) || !guards_ok()) {
            char g[33];
            hexstr(got, 16, g);
            if (bad < 10) printf("      mismatch: %s key %s len %zu got %s want %s\n",
                                 kind, khex, mlen, g, ehex);
            bad++;
        }
        release();
    }
    fclose(f);
    result(bad == 0 && n_aes + n_cmac > 0,
           "random cross-check: %d aes_encrypt + %d aes_cmac cases, %d mismatches",
           n_aes, n_cmac, bad);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *vec = NULL;
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--vectors") && i + 1 < argc) vec = argv[++i];

    printf("-- known-answer vectors through the Windows ABI wrappers\n");
    vectors(PLACE_ODD);
    vectors(PLACE_END);

    printf("-- crypto_selftest\n");
    int st = w_crypto_selftest();
    result(st == 0, "crypto_selftest returned %d", st);

    printf("-- register preservation (kernel convention)\n");
    for (size_t i = 0; i < sizeof kcases / sizeof kcases[0]; i++) {
        kcall_case(&kcases[i], 0);
        kcall_case(&kcases[i], 1);
    }

    if (vec) {
        printf("-- random cases\n");
        random_cases(vec);
    }

    printf("-- %d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
