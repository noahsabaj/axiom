/*
 * host.c - the C side of the certificate-checking test DLL (pki.dll),
 * driven from run.py with ctypes: h_k calls a kernel function by number
 * with its six register arguments, h_regs does the same and reports every
 * register before and after; the rest reads x509.asm's results.
 */
#include <stdint.h>
#include <string.h>

#define API __declspec(dllexport)
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

u64 kc(void *target, const u64 *args, int *cf);
void kcheck(void *target, const u64 *args, int *cf, u64 *regs);
const char *x5_text(int error);
extern char sha384[], sha512[], mont_setup[], mont_mul[], mont_in[], mont_out[];
extern char mont_add[], mont_sub[], mont_exp[], bn_load[], bn_store[], sig_verify[];
extern char x509_chain[], x509_leaf[], x509_parse[], x509_unix[], x509_roots[];
extern u64 x509_extra, x509_anchor;
extern u32 x509_depth;
extern u8 x509_key[];

static void *fns[] = { sha384, sha512, mont_setup, mont_mul, mont_in, mont_out,
                       mont_add, mont_sub, mont_exp, bn_load, bn_store, sig_verify,
                       x509_chain, x509_leaf, x509_parse, x509_unix };

API u64 h_k(int fn, u64 a, u64 b, u64 c, u64 d, u64 e, u64 f, int *cf)
{
    u64 args[6] = { a, b, c, d, e, f };
    return kc(fns[fn], args, cf);
}

API void h_regs(int fn, const u64 *args, int *cf, u64 *regs) { kcheck(fns[fn], args, cf, regs); }
API void h_set_extra(const void *table) { x509_extra = (u64)(uintptr_t)table; }
API const char *h_anchor(void) { return (const char *)(uintptr_t)x509_anchor; }
API int h_depth(void) { return (int)x509_depth; }
API void h_key(u8 *out) { memcpy(out, x509_key, 24); }
API const u8 *h_roots(void) { return (const u8 *)x509_roots; }
API const char *h_error_text(int code) { return x5_text(code); }
