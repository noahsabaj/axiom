# What things cost

Measured in QEMU under WHPX (Windows 11, 4 virtual CPUs unless said, 2 GiB),
on a shared host, so every number here moves by tens of percent between
boots. "Before" is `e32319b` plus the `bench` thing (`959b136`), "after" is
this branch. The two builds were run one after the other, more than once, and
compared run for run. Where the noise was larger than a change, the two ways
were timed in one boot instead (said where it was done).

Under WHPX every exit to the hypervisor costs microseconds: a WRMSR to the
TSC deadline, an IPI, a HLT woken, an MMIO register. Much of what was slow
here was exits, and real hardware pays far less for them. The fixes stand
there too, but the size of the win is QEMU's.

## How to measure

- `bench boot|sched|mem|caps|gfx|fat [path]|store|mandel` in the shell: a
  record a bench, with the area, the bench, how many, the time each and a
  rate.
- `python tools/test/bench/run.py [--areas ...] [--runs N] [--label L]`
  boots once and keeps every bench's median and spread in
  `build/test/bench/L.json`; `--compare a.json b.json` puts two side by
  side, and `--esp DIR` boots a build kept aside.
- `python tools/test/bench/net.py [--esp DIR]`: `tcp echo` over QEMU's
  RTL8139 and user network, timed from the host through a forwarded port.
- `python tools/test/bench/linux.py [--esp DIR] [--root build/linux]`:
  `linux bash -c` timing itself with `$EPOCHREALTIME`.
- `bench store` needs QEMU's test drive (serial `AXIOMTEST`), the only one
  a store may be made on.

## Before and after

The `bench` rows are from two pairs of boots on a quiet host, run
alternately, and each is the better of the two. The sched rows after the
change are from three boots of the final build, after the idle poll was
added. FAT, TCP and Linux have
sections of their own below.

| bench | before | after | |
|---|---:|---:|---:|
| sched: switch (one CPU) | 671 ns | 112–134 ns | 5.5x |
| sched: yield alone | 522 ns | 24–27 ns | 20x |
| sched: thread start + join | 8.3 us | 1.1–1.4 us | 7x |
| sched: job on every CPU | 34.7 us | 4.3–4.6 us | 8x |
| sched: wake-up across two CPUs | 0.5–9 us | 0.42–0.44 us | 2–20x |
| mem: kmalloc + kfree 16 KiB | 33.7 us | 0.81 us | 42x |
| mem: vm_alloc + free 64 KiB | 35.7 us | 3.3 us | 11x |
| mem: kmalloc + kfree 64 B / 1 KiB, a page | 61 / 127 / 34 ns | 55 / 116 / 26 ns | same |
| caps: events, handles, rings, channels | 54–262 ns | 56–269 ns | same |
| gfx: fill a 15x30 cell | 228 ns | 135 ns | 1.7x |
| gfx: glyph, opaque | 173 ns | 136 ns | 1.3x |
| gfx: glyph, blended | 560 ns | 199 ns | 2.8x |
| gfx: text colour change | 867 ns | 0.8 ns | |
| gfx: redraw a terminal | 310 us | 297 us | same |
| gfx: fill / blit / compose the screen (2560x1600) | 0.46 / 0.81 / 3.2 ms | 0.50 / 1.14 / 3.2 ms | same (noise) |
| fat: a 5.7 MB file, USB, 512 B clusters | 8.3 s | 0.10 s | 80x |
| fat: the same, NVMe, 4 KiB clusters | 0.38 s | 0.05 s | 7x |
| tcp: one-byte round trip | 4.07 ms | 0.31 ms | 13x |
| tcp: 8 MiB echoed | 16–21 MB/s | 29–37 MB/s | 1.8x |

On the busy host earlier, the gains looked bigger: switch went from 1.02 us
to 238 ns, and caps were 1.4x faster. That is because exits cost more when
the host is loaded. Whole-screen fills and copies are bound by
memory. The plain `rep stosd` and `rep movsd` were already as fast as the
memory, so the SIMD only helps short rows: cells and glyphs. The blit was not
changed. The ring and channel rows are measured inside the kernel; there is
no ring-3 system call bench yet.

## What changed, and why it was slow

**The scheduler moved the timer at every switch** (`7931551`).
`sched_arm` set the TSC deadline almost every switch, since the slice's end
and the housekeeping count are both "now + something", and each WRMSR is an
exit. A timer already set for sooner now stays; the tick it brings finds
nothing due and sets the right one. A busy CPU takes at most one extra tick a
slice. `7be677a` then sets a timer again when it is past due with no tick
yet, so a lost tick can't strand a CPU's sleepers.

**An idle CPU halted at once** (`f9745ca`). Once switching was cheap, an
idle CPU reached HLT sooner. Nearly every wake-up across CPUs then became an
IPI to a halted CPU, which under WHPX is an exit on each side, 5–11 us. The
old build often caught the CPU still on its way to HLT, so its wake-ups were
0.5 us or 9 us, depending on luck. The idle loop now watches `PC_RESCHED` and
its run queue for 50 us before HLT, and a waker sends no IPI to a CPU that
is watching. An XCHG on each side means that no wake-up can be lost.

**Every vm_free woke every idle CPU** (`bcb36c5`). A TLB shootdown sent an
IPI to each other CPU and waited, so an idle CPU left HLT only to flush and
sleep again. Now a CPU going to sleep marks itself lazy. A shootdown turns
that mark into "owes a flush" with a cmpxchg and sends IPIs only to the CPUs
that are awake, one at a time. A CPU waking flushes its whole TLB in
`isr_common` before any handler runs, so it never touches a page that was
taken away. This took kmalloc of 16 KiB (a vm region) and vm_alloc from
43 us to 1–4 us.

**The FAT reader read a cluster per request** (`4fa4be4`). A 5.7 MB program
on a stick with 512-byte clusters was 11,246 disk requests. Clusters that
follow one another in the chain now go straight into the caller's buffer in
one request, up to 1 MiB each.

**The IOMMU forgot every page on its own** (`6e0a806`). Every unmapped page
was a register-based invalidation, waited for. In caching mode (QEMU's),
every map also forgot the whole domain. A 64 KiB NVMe read was 32
invalidations, each several exits. `iommu_map_va` and `iommu_unmap_va` now
change every page first and invalidate once: page-selective for one page,
else the domain. The IOTLB still forgets before unmap returns.

**Drawing went a pixel or a row at a time** (`fec7112`, `ec1fc37`). The
SIMD paths run only where the CPU has AVX2. Drawing is on the main thread,
whose vector registers the scheduler saves; nothing draws from an interrupt.
- `gfx_fill` was `rep stosd` a row, paying its start-up cost on every short
  row. It now stores 8 pixels at a time.
- `gfx_glyph` used a 256-entry ramp, rebuilt at every colour change (1–2
  us), or blended each channel of each pixel one at a time. It now does 8
  pixels at once with the ramp's own arithmetic,
  `(fg*a + bg*(255-a) + 127) * 0x8081 >> 23`, so every pixel is the same.
  `bench gfx` checks that against the pixel-at-a-time way for every
  character.
- A non-temporal fill looked faster on the busy host but was slower on a
  quiet one, because what is drawn over a fill next reads it back. It was
  taken out again.

**A network card without an interrupt was polled every 4 ms**
(`6e68b9e`). QEMU's RTL8139 has no MSI, so that interval alone set TCP's
round trip. A frame in or out now marks the network busy. For 50 ms after
the last one, the card is polled every 0.25 ms; when idle, every 4 ms as
before.

**The loader measured the TSC over 50 ms** (`df3ea38`). When CPUID leaf
0x15 gives the crystal and the ratio, the rate is now exact and checked
against a 5 ms stall. QEMU under WHPX does not give the leaf, so there it is
still 50 ms.

## Boot

Power-on to the prompt is 2.5–3.8 s, and the firmware (OVMF) is 1.6–3.4 s
of it. The loader is about 120 ms and the kernel about 250 ms.

| stage | time |
|---|---:|
| firmware | 1.6–3.4 s |
| loader: display mode | 38–55 ms |
| loader: volume, TSC | 50 ms (the TSC measured) |
| loader: kernel, tables | 11–35 ms |
| exit to kernel | 14 ms |
| display and first frame | 40–80 ms |
| pci | 73–103 ms |
| other CPUs (3) | 12 ms |
| crypto self-test | 9–15 ms |
| the rest, each | 1–9 ms |

`pci` is MMIO reads of ECAM, each one an exit. Scanning less would risk
missing devices on real machines, so it was left as it is.

## The FAT reader

`bench fat /EFI/AXIOM/BROWSE.AXE` (5.7 MB), three boots each:

| volume | before | after |
|---|---:|---:|
| USB stick, 512 B clusters | 8.3–10.4 s | 0.10–0.12 s |
| USB stick, 4 KiB clusters | 0.9–1.2 s | 0.14–0.15 s |
| NVMe, 512 B clusters | 3.2–3.6 s | 0.6–1.5 s |
| NVMe, 4 KiB clusters | 0.38–0.41 s | 0.05–0.26 s |

The stick now reads at 40–55 MB/s, which is about what QEMU's xHCI and
usb-storage deliver.

## TCP

`tools/test/bench/net.py`: `tcp echo 7` on an RTL8139 with QEMU's user
network, driven from the host. Three boots of the old build and four of the
new, the last two with the final build:

| bench | before | after |
|---|---:|---:|
| one-byte round trip | 4.07–4.14 ms | 0.31–0.35 ms |
| 8 MiB echoed (both ways at once) | 16–21 MB/s | 29–37 MB/s |
| connect, echo, close | 22–24 ms | 9.0–11.4 ms |

A new connection's first SYN still waits for the idle 4 ms poll. The rest of
the 10 ms was not looked into. TLS has no bench yet.

## The store and NVMe

`bench store` on QEMU's NVMe (after):

| bench | time |
|---|---:|
| put 64 B + commit | 4–11 ms |
| get 64 B | 0.15–0.5 ms |
| put 64 KiB + commit | 4–10 ms (6–16 MB/s) |
| the drive's flush alone | 150–224 us |

A QEMU NVMe command costs 150–250 us. A commit is about five writes and two
flushes, and the flushes have to come in that order, so 4 ms is near what
this drive allows. The IOMMU change made little difference here.

## Linux programs

`tools/test/bench/linux.py`, bash timing itself. Before is `8c31c8e`, main's
L4 merged into the shell, since Linux processes and pipes came with L4.
These numbers are the best of three boots each, run alternately, with the
final build.

| bench | before | after |
|---|---:|---:|
| fork + exec of /usr/bin/true | 1.43 ms | 1.19 ms |
| `y=$(echo x \| cat)` | 3.0 ms | 2.8 ms |
| `seq 200000 \| wc -l` | 10.5 ms | 5.8 ms |
| a bash loop, 10,000 turns | 11.1 ms | 10.8 ms |

Nothing was changed for Linux itself. The pipe gains from the idle poll,
because a reader and a writer on two CPUs wake each other all the time. The
rest is about the size of the noise. Fork + exec at over a millisecond is the
next thing to look at: fork copies every page of the parent.

## Not done (next)

- **Compose only what is seen**: the desktop composes windows that are
  covered. This is being done with the desk rewrite (`desk_compose`).
- **PCI scan**: ~90 ms of exits. One could read only the functions a
  device's header says are there, carefully.
- **Copy-on-write fork**: fork copies each page now; bash forks for every
  command.
- **Batched store appends**: one write for a commit's records instead of
  several.
- **INTx for the RTL8139**: an interrupt instead of polling.
- **A precise flush on wake**: a waking CPU flushes its whole TLB. It could
  flush only what changed while it slept.
- **Benches still to write**: ring-3 system calls, and TLS handshakes and
  throughput.
- **Tests**: the `net` and `tlsclient` suites both make certificates in
  `build/test/tlsclient/certs`. Run at once by `all.py`, they can collide on
  `ca.srl` ("openssl x509 failed"). `net` passes when run again.
