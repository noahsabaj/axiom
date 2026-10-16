/*
 * host.c - the C side of the heap test DLL (heap.dll), driven from run.py
 * with ctypes: h_k calls kmalloc, kfree or heap_init with register
 * arguments, h_regs does the same and reports every register before and
 * after, h_stats reads the heap's counters and the stand-ins', and
 * h_stress runs random kmalloc and kfree from a thread of its own, checking
 * every object, so that several threads exercise the heap's lock.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define API __declspec(dllexport)
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

u64 kc(void *target, const u64 *args, int *cf);
void kcheck(void *target, const u64 *args, int *cf, u64 *regs);
extern char kmalloc[], kfree[], heap_init[], s_bench[];
extern u64 heap_objects, heap_bytes, heap_slabs, heap_big, heap_big_bytes;
extern u64 s_bad_count, s_bad_addr, s_bad_why, s_pages_out, s_vm_out, s_errors;
extern u8 pool[], vpool[], heap_class[];

static void *fns[] = { kmalloc, kfree, heap_init, s_bench };

API u64 h_k(int fn, u64 a, u64 b, u64 c, u64 d, u64 e, u64 f, int *cf)
{
    u64 args[6] = { a, b, c, d, e, f };
    return kc(fns[fn], args, cf);
}

API void h_regs(int fn, const u64 *args, int *cf, u64 *regs) { kcheck(fns[fn], args, cf, regs); }

API void h_stats(u64 *out)
{
    out[0] = heap_objects;
    out[1] = heap_bytes;
    out[2] = heap_slabs;
    out[3] = heap_big;
    out[4] = heap_big_bytes;
    out[5] = s_bad_count;
    out[6] = s_bad_addr;
    out[7] = s_bad_why;
    out[8] = s_pages_out;
    out[9] = s_vm_out;
    out[10] = s_errors;
    out[11] = (u64)(uintptr_t)pool;
    out[12] = (u64)(uintptr_t)vpool;
}

API const u8 *h_classes(void) { return heap_class; }

static u64 call1(void *fn, u64 a)
{
    u64 args[6] = { a, 0, 0, 0, 0, 0 };
    int cf;
    return kc(fn, args, &cf);
}

static u64 next(u64 *x)
{
    *x ^= *x << 13;
    *x ^= *x >> 7;
    *x ^= *x << 17;
    return *x;
}

struct slot { u8 *p; u32 size; u8 tag; };

/* ops random operations on a table of slots; returns the number of problems */
API u64 h_stress(u64 seed, int ops, int nslots, u64 largest)
{
    struct slot *slots = calloc((size_t)nslots, sizeof *slots);
    u64 x = seed | 1, bad = 0;
    if (!slots)
        return 1;
    for (int i = 0; i < ops + nslots; i++) {
        struct slot *s = &slots[i < ops ? next(&x) % nslots : i - ops];
        if (s->p) {
            for (u32 j = 0; j < s->size; j++)
                if (s->p[j] != (u8)(s->tag + j)) {
                    bad++;
                    break;
                }
            call1(kfree, (u64)(uintptr_t)s->p);
            s->p = 0;
            continue;
        }
        if (i >= ops)
            continue;
        u64 r = next(&x), cls = r & 255, size;
        r >>= 8;
        size = cls < 200 ? r % 1024 + 1 : cls < 250 ? r % 16384 + 1 : r % largest + 1;
        u8 *p = (u8 *)(uintptr_t)call1(kmalloc, size);
        if (!p || ((uintptr_t)p & 15)) {
            bad++;
            continue;
        }
        for (u32 j = 0; j < size; j++)
            if (p[j]) {
                bad++;
                break;
            }
        s->p = p;
        s->size = (u32)size;
        s->tag = (u8)next(&x);
        for (u32 j = 0; j < size; j++)
            p[j] = (u8)(s->tag + j);
    }
    free(slots);
    return bad;
}
