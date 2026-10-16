/*
 * sbc_test.c - host driver for the Axiom SBC encoder (src/kernel/sbc.asm),
 * linked with shim.obj. Driven by run.py:
 *
 *   sbc_test check
 *       interface checks: parameter validation and frame lengths, register
 *       preservation, output bounds, history reset, the constant tables
 *   sbc_test enc FREQ MODE BLOCKS SUBBANDS ALLOC BITPOOL SIGNAL SECONDS OUT.sbc IN.raw
 *       generate SIGNAL, write it to IN.raw (s16le, interleaved), encode it
 *       to OUT.sbc (raw SBC frames)
 *   sbc_test bench FREQ MODE BLOCKS SUBBANDS ALLOC BITPOOL FRAMES
 *       time sbc_encode on music-like input
 *   sbc_test tables
 *       print the prototype windows as assembled
 *
 * Signals: sine:F (left F, right 1.5F), chord, sweep, noise, silence, square.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <intrin.h>

extern int sbc_setup_w(int freq, int mode, int blocks, int subbands, int alloc, int bitpool);
extern int sbc_encode_w(const int16_t *pcm, uint8_t *out);
extern int sbc_samples_w(void);
extern uint64_t sbc_rc_call(int which);
extern uint64_t sbc_rc_in[16], sbc_rc_out[16];
extern const double sbc_cos[32], sbc_proto4[40], sbc_proto8[80];

static const int RATES[4] = {16000, 32000, 44100, 48000};
static const char *REGS[16] = {"rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "r8", "r9",
                               "r10", "r11", "r12", "r13", "r14", "r15", "rsp", "rax"};
static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static uint64_t rng(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static double gauss(void)
{
    double u1 = ((rng() >> 11) + 0.5) / 9007199254740992.0;
    double u2 = ((rng() >> 11) + 0.5) / 9007199254740992.0;
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

static int16_t clip16(double v)
{
    v = floor(v + 0.5);
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

/* fill pcm (n samples per channel, nch interleaved) with the named signal */
static int gen(const char *name, int rate, int nch, long n, int16_t *pcm)
{
    double nyq = rate * 0.45;
    for (long i = 0; i < n; i++) {
        double t = (double)i / rate, l = 0, r = 0;
        if (!strncmp(name, "sine:", 5)) {
            double f = atof(name + 5), g = f * 1.5 < nyq ? f * 1.5 : f * 0.75;
            l = 0.5 * sin(2 * M_PI * f * t);
            r = 0.5 * sin(2 * M_PI * g * t);
        } else if (!strcmp(name, "chord")) {
            l = 0.35 * (sin(2 * M_PI * 440.0 * t) + sin(2 * M_PI * 660.0 * t));
            r = 0.35 * (sin(2 * M_PI * 440.0 * t) + sin(2 * M_PI * 554.37 * t));
        } else if (!strcmp(name, "sweep")) {
            /* exponential sweep, 20 Hz up to 0.45 fs over the whole signal */
            double T = (double)n / rate, k = log(nyq / 20.0);
            l = 0.5 * sin(2 * M_PI * 20.0 * T / k * (exp(t / T * k) - 1.0));
            r = 0.5 * l;
        } else if (!strcmp(name, "noise")) {
            l = 0.15 * gauss();
            r = 0.15 * gauss();
        } else if (!strcmp(name, "silence")) {
            l = r = 0;
        } else if (!strcmp(name, "square")) {
            /* full scale 1 kHz, right channel inverted: overflow and clipping */
            l = fmod(t * 1000.0, 1.0) < 0.5 ? 32767.0 / 32768 : -32767.0 / 32768;
            r = -l;
        } else {
            return -1;
        }
        pcm[i * nch] = clip16(l * 32768.0);
        if (nch == 2)
            pcm[i * nch + 1] = clip16(r * 32768.0);
    }
    return 0;
}

static double now(void)
{
    LARGE_INTEGER c, f;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (double)c.QuadPart / f.QuadPart;
}

static int ref_valid(int freq, int mode, int blocks, int m, int alloc, int bp)
{
    if (freq < 0 || freq > 3 || mode < 0 || mode > 3 || alloc < 0 || alloc > 1)
        return 0;
    if (blocks != 4 && blocks != 8 && blocks != 12 && blocks != 16)
        return 0;
    if (m != 4 && m != 8)
        return 0;
    return bp >= 2 && bp <= 250 && bp <= (mode < 2 ? 16 : 32) * m;
}

static int ref_len(int mode, int blocks, int m, int bp)
{
    int nch = mode == 0 ? 1 : 2;
    if (mode < 2)
        return 4 + 4 * m * nch / 8 + (blocks * nch * bp + 7) / 8;
    return 4 + 4 * m * 2 / 8 + ((mode == 3 ? m : 0) + blocks * bp + 7) / 8;
}

/* run one entry point with patterned registers; report any that changed */
static uint64_t rc_run(int which, uint64_t rsi, uint64_t rdi, uint64_t misalign, const char *what)
{
    for (int i = 0; i < 16; i++)
        sbc_rc_in[i] = 0x0123456789ABCDEFull * (i + 3) ^ (rng() & 0xFFFF0000FFFF0000ull);
    sbc_rc_in[3] = rsi;
    sbc_rc_in[4] = rdi;
    sbc_rc_in[14] = misalign;
    uint64_t ret = sbc_rc_call(which);
    for (int i = 0; i < 14; i++)
        CHECK(sbc_rc_out[i] == sbc_rc_in[i], "%s changed %s", what, REGS[i]);
    CHECK(sbc_rc_out[14] == 0, "%s unbalanced stack", what);
    return ret;
}

static void check_setup_regs(int freq, int mode, int blocks, int m, int alloc, int bp, uint64_t misalign)
{
    /* 32-bit arguments with junk in the upper halves, which must be ignored */
    for (int i = 0; i < 16; i++)
        sbc_rc_in[i] = 0x0123456789ABCDEFull * (i + 7);
    uint64_t hi = 0xA5A5A5A500000000ull;
    sbc_rc_in[4] = hi | (uint32_t)freq;     /* rdi */
    sbc_rc_in[3] = hi | (uint32_t)mode;     /* rsi */
    sbc_rc_in[2] = hi | (uint32_t)blocks;   /* rdx */
    sbc_rc_in[1] = hi | (uint32_t)m;        /* rcx */
    sbc_rc_in[6] = hi | (uint32_t)alloc;    /* r8 */
    sbc_rc_in[7] = hi | (uint32_t)bp;       /* r9 */
    sbc_rc_in[14] = misalign;
    uint32_t ret = (uint32_t)sbc_rc_call(0);
    for (int i = 0; i < 14; i++)
        CHECK(sbc_rc_out[i] == sbc_rc_in[i], "sbc_setup changed %s", REGS[i]);
    CHECK(sbc_rc_out[14] == 0, "sbc_setup unbalanced stack");
    int want = ref_valid(freq, mode, blocks, m, alloc, bp) ? ref_len(mode, blocks, m, bp) : 0;
    CHECK(ret == (uint32_t)want, "sbc_setup with junk upper halves: %u, want %d", ret, want);
}

static int do_check(void)
{
    static int16_t pcm[16 * 8 * 2 * 64], pcm2[sizeof pcm / 2];
    static uint8_t out[2048], a[64 * 600], b[64 * 600];

    /* never set up: nothing to encode */
    CHECK(sbc_samples_w() == 0, "sbc_samples before setup");
    memset(out, 0xAA, sizeof out);
    CHECK(sbc_encode_w(pcm, out) == 0 && out[0] == 0xAA, "sbc_encode before setup");

    /* every parameter combination around the limits */
    static const int bps[] = {-1, 0, 1, 2, 3, 31, 53, 63, 64, 65, 127, 128, 129, 249, 250, 251, 255, 256, 1000};
    static const int ms[] = {-8, 0, 2, 4, 5, 6, 8, 12, 16};
    long combos = 0, valid = 0;
    for (int freq = -1; freq <= 4; freq++)
        for (int mode = -1; mode <= 4; mode++)
            for (int blocks = -4; blocks <= 20; blocks++)
                for (unsigned mi = 0; mi < sizeof ms / sizeof *ms; mi++)
                    for (int alloc = -1; alloc <= 2; alloc++)
                        for (unsigned bi = 0; bi < sizeof bps / sizeof *bps; bi++) {
                            int m = ms[mi], bp = bps[bi];
                            int got = sbc_setup_w(freq, mode, blocks, m, alloc, bp);
                            int ok = ref_valid(freq, mode, blocks, m, alloc, bp);
                            int want = ok ? ref_len(mode, blocks, m, bp) : 0;
                            combos++;
                            valid += ok;
                            if (got != want) {
                                CHECK(0, "setup(%d,%d,%d,%d,%d,%d) = %d, want %d", freq, mode, blocks, m, alloc, bp, got, want);
                                continue;
                            }
                            int spf = sbc_samples_w();
                            CHECK(spf == (ok ? blocks * m : 0), "sbc_samples after setup(%d,%d,%d,%d,%d,%d) = %d",
                                  freq, mode, blocks, m, alloc, bp, spf);
                        }
    printf("setup: %ld parameter sets, %ld valid, lengths and validation as specified\n", combos, valid);
    CHECK(sbc_setup_w(2, 3, 16, 8, 0, 53) == 119, "the A2DP high-quality joint stereo frame is 119 bytes");

    /* register preservation, on an 8- and a 16-byte aligned stack */
    gen("noise", 44100, 2, 128, pcm);
    for (uint64_t mis = 0; mis <= 8; mis += 8) {
        check_setup_regs(2, 3, 16, 8, 0, 53, mis);
        check_setup_regs(1, 0, 4, 4, 1, 20, mis);
        check_setup_regs(9, 0, 4, 4, 1, 20, mis);       /* invalid: 0 */
        check_setup_regs(2, 2, 16, 8, 0, 256, mis);     /* bitpool too big: 0 */
        sbc_setup_w(2, 3, 16, 8, 0, 53);
        uint64_t ret = rc_run(1, (uint64_t)pcm, (uint64_t)out, mis, "sbc_encode");
        CHECK((uint32_t)ret == 119, "sbc_encode via rc_call returned %u", (uint32_t)ret);
        ret = rc_run(2, 0, 0, mis, "sbc_samples");
        CHECK((uint32_t)ret == 128, "sbc_samples via rc_call returned %u", (uint32_t)ret);
    }
    printf("registers: sbc_setup, sbc_encode, sbc_samples preserve all but RAX\n");

    /* writes exactly one frame, leaves the input alone, every mode */
    static const int cfg[][6] = {
        {2, 3, 16, 8, 0, 53}, {3, 3, 16, 8, 0, 51}, {2, 2, 16, 8, 1, 250}, {2, 1, 16, 8, 0, 128},
        {2, 0, 16, 8, 0, 128}, {0, 0, 4, 4, 1, 2}, {1, 3, 12, 4, 0, 128}, {2, 1, 8, 4, 1, 64},
    };
    for (unsigned c = 0; c < sizeof cfg / sizeof *cfg; c++) {
        const int *p = cfg[c];
        int len = sbc_setup_w(p[0], p[1], p[2], p[3], p[4], p[5]);
        int spf = sbc_samples_w(), nch = p[1] ? 2 : 1;
        for (int s = 0; s < 3; s++) {
            gen(s == 0 ? "square" : s == 1 ? "noise" : "sweep", RATES[p[0]], nch, spf, pcm);
            memcpy(pcm2, pcm, spf * nch * 2);
            memset(out, 0xAA, sizeof out);
            int got = sbc_encode_w(pcm, out);
            CHECK(got == len, "config %u: encode returned %d, setup said %d", c, got, len);
            int clean = 1;
            for (int i = len; i < (int)sizeof out; i++)
                clean &= out[i] == 0xAA;
            CHECK(clean, "config %u: wrote past the frame", c);
            CHECK(!memcmp(pcm, pcm2, spf * nch * 2), "config %u: input changed", c);
            CHECK(out[0] == 0x9C && out[2] == p[5], "config %u: header", c);
        }
    }
    printf("frames: one frame of exactly the set-up length, input untouched\n");

    /* setup resets the filter history: same input, same frames */
    for (int round = 0; round < 2; round++) {
        uint8_t *dst = round ? b : a;
        sbc_setup_w(2, 3, 16, 8, 0, 53);
        rng_state = 12345;
        gen("noise", 44100, 2, 128 * 64, pcm);
        for (int f = 0; f < 64; f++)
            sbc_encode_w(pcm + f * 256, dst + f * 119);
        if (!round) {   /* something else in between */
            sbc_setup_w(0, 1, 4, 4, 1, 20);
            sbc_encode_w(pcm, out);
        }
    }
    CHECK(!memcmp(a, b, 64 * 119), "setup does not reset the history");
    printf("reset: identical frames after a second setup\n");

    /* the constant tables, as NASM assembled them */
    double worst = 0;           /* the first quadrant against libm, the rest by symmetry */
    for (int m = 0; m <= 8; m++)
        worst = fmax(worst, fabs(sbc_cos[m] - cos(m * M_PI / 16)));
    CHECK(worst < 2.5e-16, "cos table off by %g", worst);
    for (int m = 9; m < 32; m++) {
        double want = m <= 16 ? -sbc_cos[16 - m] : m <= 24 ? -sbc_cos[m - 16] : sbc_cos[32 - m];
        CHECK(sbc_cos[m] == want, "cos table entry %d not symmetric", m);
    }
    for (int t = 0; t < 2; t++) {
        int M = t ? 8 : 4, N = 10 * M;
        const double *c = t ? sbc_proto8 : sbc_proto4;
        double sum = 0, asym = 0;
        for (int n = 0; n < N; n++) {
            double h = c[n] * ((n / (2 * M)) & 1 ? -1 : 1);
            sum += h;
            if (n) {
                int k = N - n;
                asym = fmax(asym, fabs(h - c[k] * ((k / (2 * M)) & 1 ? -1 : 1)));
            }
        }
        CHECK(asym == 0 && fabs(sum - 2.0) < 1e-3, "proto%d: symmetry %g, sum %g", M, asym, sum);
    }
    CHECK(sbc_proto8[40] == 1.46955068E-01 && sbc_proto4[20] == 2.94315332E-01, "proto centre taps");
    printf("tables: cos(m pi/16) within %.1e, prototypes symmetric with gain 2\n", worst);

    printf(failures ? "check: %d FAILURES\n" : "check: all passed\n", failures);
    return failures ? 1 : 0;
}

static int args_cfg(char **argv, int *p)
{
    for (int i = 0; i < 6; i++)
        p[i] = atoi(argv[i]);
    return sbc_setup_w(p[0], p[1], p[2], p[3], p[4], p[5]);
}

static int do_enc(char **argv)
{
    int p[6], len = args_cfg(argv, p);
    if (!len) {
        fprintf(stderr, "invalid configuration\n");
        return 2;
    }
    const char *sig = argv[6];
    double secs = atof(argv[7]);
    int rate = RATES[p[0]], nch = p[1] ? 2 : 1, spf = sbc_samples_w();
    long frames = (long)(secs * rate) / spf, n = frames * spf;
    int16_t *pcm = malloc(n * nch * 2 + 16);
    uint8_t *out = malloc(frames * len + 16);
    if (gen(sig, rate, nch, n, pcm)) {
        fprintf(stderr, "unknown signal %s\n", sig);
        return 2;
    }
    double t0 = now();
    long bytes = 0;
    for (long f = 0; f < frames; f++) {
        int got = sbc_encode_w(pcm + f * spf * nch, out + bytes);
        if (got != len) {
            fprintf(stderr, "frame %ld: %d bytes, expected %d\n", f, got, len);
            return 1;
        }
        bytes += got;
    }
    double t1 = now();
    FILE *fo = fopen(argv[8], "wb"), *fi = fopen(argv[9], "wb");
    if (!fo || !fi)
        return 2;
    fwrite(out, 1, bytes, fo);
    fwrite(pcm, 2, n * nch, fi);
    fclose(fo);
    fclose(fi);
    printf("frames=%ld len=%d samples=%ld ns_per_frame=%.0f\n", frames, len, n, (t1 - t0) * 1e9 / frames);
    return 0;
}

static int do_bench(char **argv)
{
    int p[6], len = args_cfg(argv, p);
    if (!len)
        return 2;
    long frames = atol(argv[6]);
    int rate = RATES[p[0]], nch = p[1] ? 2 : 1, spf = sbc_samples_w();
    long n = 64L * spf;
    int16_t *pcm = malloc(n * nch * 2);
    static uint8_t out[1024];
    gen("chord", rate, nch, n, pcm);
    for (long i = 0; i < n * nch; i++)      /* chord plus a little noise */
        pcm[i] = clip16(pcm[i] + 300.0 * gauss());
    double best = 1e9;
    uint64_t best_cyc = ~0ull;
    for (int rep = 0; rep < 5; rep++) {
        double t0 = now();
        uint64_t c0 = __rdtsc();
        for (long f = 0; f < frames; f++)
            sbc_encode_w(pcm + (f & 63) * spf * nch, out);
        uint64_t c1 = __rdtsc();
        double t1 = now();
        best = fmin(best, (t1 - t0) / frames);
        if ((c1 - c0) / frames < best_cyc)
            best_cyc = (c1 - c0) / frames;
    }
    printf("bench: %d bytes/frame, %.2f us/frame (%llu TSC cycles), frame period %.0f us\n",
           len, best * 1e6, (unsigned long long)best_cyc, spf * 1e6 / rate);
    return 0;
}

/* the prototype windows as assembled, for run.py to compare with ref.py */
static int do_tables(void)
{
    printf("proto4");
    for (int i = 0; i < 40; i++)
        printf(" %.17g", sbc_proto4[i]);
    printf("\nproto8");
    for (int i = 0; i < 80; i++)
        printf(" %.17g", sbc_proto8[i]);
    printf("\n");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "check"))
        return do_check();
    if (argc >= 2 && !strcmp(argv[1], "tables"))
        return do_tables();
    if (argc >= 12 && !strcmp(argv[1], "enc"))
        return do_enc(argv + 2);
    if (argc >= 9 && !strcmp(argv[1], "bench"))
        return do_bench(argv + 2);
    fprintf(stderr, "usage: sbc_test check | enc F MODE BLK SB ALLOC BP SIGNAL SECS OUT.sbc IN.raw"
                    " | bench F MODE BLK SB ALLOC BP FRAMES\n");
    return 2;
}
