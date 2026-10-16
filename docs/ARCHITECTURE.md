# Axiom architecture (M0)

Everything here is NASM in `-f bin` mode: no linker, no object files. Two
images come out of the build, and the second contains the first.

## Boot: `src/boot/uefi.asm`

The loader is a PE32+ UEFI application assembled by hand: DOS stub, PE
header, a `.text` section and a `.reloc` section holding one block of no-op entries (the
code is position-independent, but some firmware refuses images without one).
It calls firmware services with the Microsoft x64 ABI. It refuses to run if
the firmware left 5-level paging on.

1. Pick the largest Graphics Output Protocol mode (up to `GOP_MAX_W×GOP_MAX_H`
   if the build caps it) and record the framebuffer.
2. Find the ACPI 2.0 RSDP and the SMBIOS 3 (or 2) entry point in the
   configuration table.
3. Read the first sector of the volume the loader came from (`LoadedImage`'s
   device handle, its `BlockIo`) and keep its FAT volume serial number, so the
   kernel can find that stick again for its log. Never fatal.
4. Calibrate the TSC against the firmware's `Stall` (50 ms).
5. Copy the embedded `kernel.bin` (an `incbin`) into fresh pages, zero its
   `.bss`, and build page tables:
   - `PML4[0]`: identity map of physical memory in 2 MiB pages, needed for
     the moment of the CR3 switch and for UEFI runtime calls;
   - `PML4[256]`: the same tables again at `0xFFFF800000000000`, the direct map
     the kernel uses for all physical memory (at least the first 4 GiB, so the
     usual MMIO hole is covered);
   - `PML4[511]`: the kernel at `0xFFFFFFFF80000000` in 4 KiB pages, and the
     framebuffer at `0xFFFFFFFF00000000` write-combining (PAT entry 4).
6. Take the final memory map and call `ExitBootServices` (retrying if the map
   changed). `SetVirtualAddressMap` is never called: runtime services stay
   identity mapped, so `ResetSystem` keeps working.
7. Load CR3, jump to `kernel_main` with a boot-information block
   (`src/include/bootinfo.inc`): memory map, framebuffer, ACPI, SMBIOS, TSC
   frequency, runtime-services table, boot volume serial.

Placing the kernel in the top 2 GiB matters for assembly: every label is a
sign-extended 32-bit value, so `[table + rax*8]` and `push label` encode
directly with no RIP-relative gymnastics.

## Kernel image: `src/kernel/kernel.asm`

One file that `%include`s every module into four sections (`.text`,
`.rodata`, `.data`, `.bss`) laid out back to back. The first bytes are a
header the loader reads: magic `AXIOMKRN`, entry point, file size, memory
size. `build/kernel.map` lists every symbol.

`kernel_main` (`boot.asm`) brings the machine up in dependency order:

| Step | Module | What |
|---|---|---|
| 1 | `gdt.asm`, `idt.asm` | Our GDT, the BSP's per-CPU block in GS, 256 interrupt stubs |
| 2 | `serial.asm`, `lib.asm`, `log.asm` | COM1 log, TSC time base, `sprintf`, `KLOG`; the clock and the boot volume into the log |
| 3 | `cpu.asm` | CPUID features and brand, hybrid core types, PAT, NX, SSE/AVX through XSETBV, HWP, telemetry MSRs |
| 4 | `pmm.asm` | Bitmap page allocator from the UEFI memory map |
| 5 | `gfx.asm`, `console.asm`, `ui.asm` | Framebuffer, alpha-blended glyphs, the dashboard and console |
| 6 | TSS, IST | #DF, NMI and #MC each get their own stack |
| 7 | `acpi.asm`, `smbios.asm` | MADT (CPUs, I/O APICs, overrides), MCFG, FADT, `_S5_`; board, BIOS and memory strings |
| 8 | `pmm.asm` | Reclaim boot-services memory |
| 9 | `apic.asm` | x2APIC through MSRs, else xAPIC MMIO; 8259s masked; I/O APIC entries masked |
| 10 | `smp.asm` | Start every other thread (below) |
| 11 | `pci.asm` | Enumerate through ECAM, else ports CF8/CFC |
| 12 | `kbd.asm`, `usb.asm` | PS/2 keyboard on IRQ 1; xHCI controllers and whatever is plugged in at boot (later devices arrive through hot-plug in the main loop) |
| 13 | `nvme.asm`, `disk.asm`, `fat.asm` | NVMe controllers, their partitions (and those of USB sticks found in step 12), FAT32 mounted read-only |
| 14 | `net.asm`, `rtl8168.asm` | Ethernet controllers; DHCP starts once the link is up |
| 15 | `mandel.asm`, `shell.asm` | Palette, view, shell; interrupts on |

Then `main_loop`: poll and service USB (enumeration, hot-plug), service the
network (frames in, link, DHCP/ARP/ping timers), save the log if it grew
(every 10 s), apply pointer movement, take input, refresh telemetry every 500 ms, render a demo frame at
most every 16 ms (or at once after a click or the wheel), and otherwise sleep
with `hlt` until the next deadline, armed on the TSC-deadline timer: the next
refresh or frame, the next key repeat, the next network timer, or 4 ms while
a USB controller or a network card needs polling. A USB event, a network
interrupt or pointer movement wakes it early.

## Memory

- **Physical:** one bit per 4 KiB page, built from the UEFI memory map. The
  kernel, its page tables and the loader's allocations are marked used; boot
  services memory is released after ACPI and SMBIOS have been read.
- **Virtual:** fixed. Physical memory at `PHYS_BASE + pa`; MMIO above the
  direct map goes into an uncached 1 GiB window at `0xFFFF808000000000`
  (`mmio_map` in `usb.asm`). There are no per-task address spaces yet: that is
  M1.

## Processors: `smp.asm`

- The MADT gives the APIC IDs. The BSP is moved to index 0.
- A 16-bit trampoline is copied below 1 MiB. The BSP patches in the GDT, CR3
  and the 64-bit entry, then sends INIT to every AP at once, waits 10 ms and
  sends two rounds of SIPIs. Each AP goes 16 → 32 → 64-bit, finds its own index
  by matching its x2APIC ID (CPUID leaf 0xB) and sets up its GS block, TSS, IST
  stacks, LAPIC and features.
- `smp_topology` sorts threads by kind (P-core, E-core, other), then APIC ID,
  and numbers cores within each kind. That order drives the dashboard tiles.
- **Jobs:** `job_run(fn, items, arg)` wakes every CPU with an IPI on
  `VEC_WAKE`; all of them, the BSP included, claim items with `lock xadd`
  until none are left and check in. `job_run_each` runs a function once per
  CPU (telemetry sampling uses it). Idle APs sleep in `hlt` with interrupts
  enabled only around the check, so a wake-up can't be missed.
- `smp_stop_others` sends NMI to every other CPU; panic uses it.

## Interrupts

Vectors: `0x21` PS/2 keyboard (I/O APIC, with MADT overrides applied), `0x22`
xHCI and `0x23` network cards (MSI-X or MSI to the BSP, set up by `pci_msi`), `0x30` TSC-deadline timer, `0x40` job wake-up, `0xFF`
spurious. Every stub saves all general registers and calls the handler
registered with `irq_register`; the common path sends the EOI. Exceptions go
to `panic`, which stops the other CPUs and paints a full report (registers,
CR2, CR3, segments) on screen and serial.

## USB: `usb.asm`, `usbdev.asm`, `usbhub.asm`, `hid.asm`, `usbmsc.asm`, `pointer.asm`

- **Controllers** (`usb.asm`): each xHCI controller (PCI class 0C/03/30) is
  taken from the firmware through the USB legacy-support capability (BIOS
  semaphore, SMIs off), reset, and given a device context array, scratchpad
  buffers, a command ring and one 256-entry event ring. Events arrive by MSI-X
  or MSI, aimed at the BSP; the main loop also drains the event rings with
  interrupts off, so a controller without either still works.
- **Devices** (`usbdev.asm`): enumeration and hot-plug run from the main loop
  with synchronous control transfers, one device at a time. Each device gets
  a slot, an address and its descriptors; each interface is offered to the
  class drivers in turn. `usb` lists the tree.
- **Hubs** (`usbhub.asm`): USB 2 and USB 3 hubs, nested, with the route string
  and transaction-translator fields xHCI needs for low- and full-speed devices
  behind high-speed hubs. The status-change endpoint drives hot-plug.
- **HID** (`hid.asm`): the report descriptor is parsed into the fields Axiom
  uses: key arrays and bitmaps (6-key and N-key rollover), buttons, X/Y
  (relative or absolute), wheel and pan, each with its report ID. Devices that
  describe nothing useful but claim the boot subclass fall back to boot
  protocol. Keys become characters through a usage table, with a 500 ms /
  30 Hz repeat.
- **Mass storage** (`usbmsc.asm`): sticks and card readers that speak
  Bulk-Only Transport with SCSI commands (class 08/06/50). INQUIRY names the
  device, TEST UNIT READY waits up to 3 s for a medium, READ CAPACITY (10,
  else 16) sizes it, and the stick becomes a removable disk. Reads and
  writes go in 64 KiB pieces through one bounce buffer (READ/WRITE 10, or 16
  past 2^32 blocks), polled, 8 s per transfer. A stalled endpoint is reset
  and cleared; a command that goes wrong gets a Bulk-Only reset; a unit
  attention is retried once; a write-protect switch is reported. Pulling the
  stick marks its disk and volumes gone, and a stick plugged in later reuses
  the slots.
- **Pointer** (`pointer.asm`): HID posts movement into a ring from interrupt
  context; the main loop applies it with acceleration, scaled to the screen.
  The cursor is drawn only on the framebuffer: `gfx_blit` repaints it over
  whatever it copies, so the back buffer never holds it.

## Storage: `nvme.asm`, `usbmsc.asm`, `disk.asm`, `fat.asm`

- **NVMe** (`nvme.asm`): each controller (PCI 01/08/02) is reset and given an
  admin queue pair and one I/O queue pair, polled. Commands complete in
  microseconds, so the caller waits. Identify gives the model, firmware,
  transfer limit and the first active namespace. Data moves through one
  physically contiguous 64 KiB bounce buffer with a prebuilt PRP list, so
  callers can use any kernel buffer. Per-core queues and interrupts come with
  M1's scheduler.
- **Disks and volumes** (`disk.asm`): a driver registers a disk with a table
  of operations (read, write, flush, describe). GPT partitions (else MBR, else
  a filesystem on the bare disk) become volumes, each probed for FAT32, FAT16,
  exFAT or NTFS. Every volume starts **read-only**: `vol <n> rw` unlocks one,
  `vol <n> ro` locks it again, and `vol_write` refuses anything else. The
  one exception is the log on the boot stick (below).
  The current volume is the first FAT32 volume on a removable disk (the USB
  stick Axiom booted from, usually), else the first FAT32 volume anywhere,
  until `vol <n>` picks one. A disk that goes away takes its volumes with
  it; a stick plugged in again comes back read-only.
- **FAT32** (`fat.asm`): long names are read and written; a new long name gets
  the shortest `NAME~n.EXT` alias nothing else in the directory has, and an 8.3
  name in one case is stored as 8.3 with the lowercase flags Windows uses.
  There is one cached FAT sector (written to every FAT copy) and one cached
  directory sector; file data goes straight to its clusters. Every operation
  ends by flushing both caches, updating FSInfo's next-free hint and telling
  the drive to flush. Replacing a file empties its entry before freeing the
  old clusters, so an interrupted write leaves an empty file, not a dangling
  chain.
- Shell: `disks`, `vol`, `ls`, `cd`, `cat`, `cp`, `write`, `mkdir`, `rm`.
  File times come from the CMOS clock (`rtc.asm`, also `date`).
- Tested in QEMU against images from `tools/mkdisk.py` (512-byte and 64 KiB
  clusters, two drives at once, a USB stick direct and behind a hub, pulled
  and plugged in again), checked by `tools/fatcheck.py` and 7-Zip.
  Not yet: 4 KiB-sector drives tested, UAS (USB Attached SCSI), exFAT/NTFS.

## Log: `log.asm`

Every `KLOG` line (and every shell command line) also goes into a 1 MiB
buffer, so the whole log of a boot is kept; past 1 MiB it says it is full and
stops. `log.asm` saves it as `/AXIOM.LOG` on the boot stick: the one
**removable**, mounted FAT32 volume whose serial number matches the one the
loader read. A fixed disk never qualifies, nor does any other stick; two
sticks with the same serial and neither is written. That one file needs no
`vol <n> rw`: the volume is made writable for the save and put back as it was.

Saved once the stick is mounted after boot, then every 10 s while the log
grows, before `reboot` and `poweroff`, and after a panic: the report is
appended and saved, unless the crash came in the middle of a FAT write
(`fat_need_rw` sets `fat_writing`, the shell clears it between commands),
when the FAT code's state can't be trusted. USB transfers are polled, so the
save works with interrupts off. A failed automatic save turns automatic saving
off. `log` shows the state; `log save`, `log on`, `log off`.

## Network: `rtl8168.asm`, `net.asm`, `tcp.asm`, `netapp.asm`, `http.asm`

- **Realtek** (`rtl8168.asm`): the RTL8111/8168 family (the Victus's "Gaming
  GbE", 10EC:8168), and the RTL8139C+ QEMU emulates, whose C+ mode uses the
  same descriptor rings and registers except the transmit poll and the link
  bits. G-family chips (XID 4c0 and later) are first taken from their
  out-of-band firmware and their RX gate is closed around the reset, as
  Linux does; the PHY gets an autonegotiation restart only if it was left
  powered down, isolated or forced. One receive ring (64 descriptors) and
  one transmit ring (32), a 2 KiB buffer each; frames are copied in and out.
  MSI-X or MSI wakes the main loop, which polls the ring; without either
  (QEMU's 8139) it polls every 4 ms.
- **Stack** (`net.asm`): drivers register an interface with a table of
  operations (send, poll, link, ack) and hand frames to `net_receive`. The
  first interface carries the one IPv4 address. ARP keeps 16 neighbours for
  five minutes and holds up to four frames while it asks (three times, a
  second apart). IPv4 checks header checksums, drops fragments, and routes
  through the gateway when the destination is off the subnet. ICMP answers
  echo requests sent to us; UDP checks checksums and hands port 68 to DHCP
  and the resolver's port to DNS; protocol 6 goes to TCP. Addresses stay in network byte order
  throughout (`%I` prints them, `%M` prints a MAC).
- **Clients** (`netapp.asm`): DHCP (discover, request, renew at half the
  lease, start over on NAK or link up), an A-record resolver (three tries,
  2 s apart) and ping (a TSC stamp in each request gives the round trip).
  Each runs on `net_service`'s timers, so the prompt comes back at once;
  ctrl+C stops a ping or a lookup.
- **TCP** (`tcp.asm`): the client side, eight connections. Something in
  the kernel opens one with a table of four handlers (open, data, the other
  side's FIN, gone and why) and writes into an 8 KiB send buffer. MSS 1460
  is offered and the peer's honoured; the window offered is a fixed 64240,
  because handlers take every byte as it comes. Retransmission follows RFC
  6298 (smoothed RTT and its variation in TSC ticks, Karn's rule, doubling,
  200 ms to 60 s, eight tries); RFC 5681's slow start and congestion
  avoidance start from a ten-segment window; three duplicate ACKs resend
  the oldest segment at once, and during that recovery each partial ACK
  resends the next hole (NewReno, RFC 6582). A closed window is probed one byte at a time,
  and when it opens the probe is resent at once. Segments
  after a gap are dropped and the ACK repeats what is missing; overlapping
  ones are trimmed. A segment for no connection gets a reset. Both closes
  work; TIME_WAIT lasts 10 s, and a new connection may take over a slot in
  it. `tcp` lists connections with their state, bytes and round trip.
- **HTTP** (`http.asm`): `http <host[:port][/path]> [file]`, one GET at a
  time over HTTP/1.0 (so no chunks, and the server's close ends the body).
  Up to 1 MiB of the answer is kept; then the status line, `Content-Type`
  and `Location`, and the first 20 lines of the body, or the body goes to a
  file on the current volume. `https://` goes over `tls.asm` (below), port
  443 unless given: the TCP handlers pass bytes to `tls_input`, and the TLS
  handlers hand the plaintext to the same code. A TCP FIN without a
  close_notify first is reported (the answer may be cut short).
- Shell: `net`, `ip`, `dhcp`, `ping`, `host`, `arp`, `tcp`, `http`.
- Tested in QEMU with `tools/run.py --nic rtl8139`: DHCP, ping and DNS
  through QEMU's user network, and two Axiom VMs joined by a socket pinging
  each other, with every frame's checksums checked in the dump
  (`build/net-PORT.pcap`). HTTP from a server on the host (QEMU's 10.0.2.2)
  and from example.com, a 300 KB file saved and compared byte for byte.
  `tools/netpeer.py` is a deliberately unreliable peer on QEMU's socket
  backend: it drops the first SYN, the request, and data segments; reorders
  and duplicates others; refuses, resets, keeps silent, holds a zero window,
  and asks for 64-byte segments, with three duplicate ACKs at a gap. Every
  case completes, and the 200 KB it serves through the losses arrives
  intact. The RTL8168 code paths (G-family takeover, PHY, MSI) run only on
  real hardware. Not yet: certificate checks, a TCP server side, IPv6,
  other NICs.

## TLS: `tls.asm`, `rand.asm`, `sha256.asm`, `aesgcm.asm`, `x25519.asm`

A TLS 1.3 client (RFC 8446) and the crypto under it.

- **The client** (`tls.asm`): one connection at a time, independent of what
  carries its bytes (a send function in, `tls_input` for what arrives, and
  four handlers out: READY, DATA, CLOSED, FAIL). It offers only
  TLS_AES_128_GCM_SHA256 and an X25519 key share, with server name
  indication, a random session id and the change_cipher_spec of RFC 8446
  D.4 for middleboxes. It reassembles records across TCP segments and
  handshake messages across records (up to 64 KiB each), keeps the
  transcript hash, runs the key schedule (early, handshake, master secrets;
  traffic keys and IVs; per-record nonces), checks the server's Finished in
  constant time, sends its own, strips record padding, ignores session
  tickets, follows KeyUpdate both ways, and ends with close_notify. A
  failure sends the matching alert and wipes every key. **The certificate
  chain is counted, not verified**: the connection is private and
  tamper-proof against anyone who is not in the middle, but nothing yet
  proves the server is who it claims to be. Verifying it needs X.509, RSA
  and ECDSA signatures, and a set of trusted roots.
- **Random numbers** (`rand.asm`): a SHA-256 pool stirred with RDSEED (else
  RDRAND) and the TSC on every call, moved on after each use; TLS refuses
  to start on a CPU with neither.
- `tools/test/tlsclient/run.py` builds the client into a DLL and runs it
  against Python's ssl module (OpenSSL 3.5) as the server, over memory
  buffers that deliver bytes in pieces down to one at a time: RSA and ECDSA
  certificates, a 21-certificate chain of 16 KB, no SNI for an address,
  200 KB down, 40 handshakes writing from inside READY, close_notify both
  ways; a flipped bit, TLS 1.2-only, client-certificate and P-256-only
  servers, a full connection, a cut-off handshake. A hand-made server
  (`minisrv.py`, on the pure-Python references) covers what OpenSSL will not
  do on request: a wrong Finished, KeyUpdate with and without a request,
  padding, empty records, messages cut across records, oversized records.
  Live, the same DLL fetched pages from example.com, cloudflare.com,
  google.com and github.com.
- In QEMU, `http https://example.com/` and a 300 KB file from
  `tools/httpsd.py` (saved, compared byte for byte).

- **SHA-256** (`sha256.asm`): one call or init/update/final over a context
  the caller owns (copyable, so a transcript hash can be forked). Blocks go
  through the SHA extensions when CPUID has them (`sha256rnds2`,
  `sha256msg1/2`), else plain x86; `sha256_mode` says which. On top: HMAC,
  HKDF-Extract and -Expand (RFC 5869) and TLS 1.3's HKDF-Expand-Label
  (RFC 8446 7.1).
- **AES-128-GCM** (`aesgcm.asm`): key expansion with `aeskeygenassist`,
  counter mode with `aesenc`, GHASH with four `pclmulqdq` and Gueron's
  reduction on byte-reflected blocks. Seals and opens in place, tag after
  the data; opening compares the tag in constant time and leaves the record
  untouched when it is wrong. `gcm_supported` says whether the CPU can.
- **X25519** (`x25519.asm`, RFC 7748): field elements as four 64-bit limbs,
  products folded with 2^256 = 38 (mod p), a 255-step Montgomery ladder with
  masked swaps; no branch or memory address depends on the secret scalar,
  and the scratch is wiped afterwards.
- All three preserve every general register but RAX and clobber at most
  XMM0-XMM10; their scratch is in .bss, so main loop only.
- `cryptotest.asm` checks each against its published vectors (FIPS 180-4,
  RFC 4231, RFC 5869, RFC 8448, GCM test case 4 with a forged tag refused,
  RFC 7748) at boot, both SHA-256 paths when the CPU has SHA-NI, and logs one
  line. `crypto` repeats the check and times SHA-256 (each way), AES-GCM and
  one X25519.
- `tools/test/tls/run.py` runs them on the host: the published vectors plus
  about 670 random cases from independent references (hashlib; a pure-Python
  AES-GCM and X25519 written from SP 800-38D and RFC 7748, each made to
  reproduce the published vectors first), every buffer at odd addresses or
  against a no-access page, hashes fed in uneven pieces, a flipped bit in
  tag, ciphertext and additional data refused, X25519's non-canonical inputs,
  RFC 7748's 1000-fold iteration, register preservation through `kcall`, all
  with plain-x86 SHA-256 and again with SHA-NI. On this i7-14700F: SHA-256
  about 1.6 GB/s on SHA-NI (210 MB/s plain), AES-128-GCM 575 MB/s, X25519
  64 us.

## Graphics and text: `gfx.asm`, `console.asm`, `ui.asm`

The framebuffer is mapped write-combining, so stores stream out in 64-byte
bursts. The font is Cascadia Mono rasterized at three sizes by
`tools/mkfont.py` into 8-bit coverage maps; glyphs are alpha-blended over the
background. The kernel picks the largest size that still leaves at least 50
text rows. The dashboard is laid out in font cells: header, SYSTEM and
CONSOLE on the left, PROCESSORS tiles and the MANDELBROT view on the right.

## Telemetry: `cpu.asm`

- **Clock:** the APERF/MPERF ratio over each 500 ms interval, times the TSC
  frequency.
- **Temperature:** `IA32_THERM_STATUS` against `MSR_TEMPERATURE_TARGET`
  (TjMax).
- **Package power:** the RAPL energy counter's delta, scaled by its unit.
- Every CPU samples its own MSRs in a `job_run_each`. A reading that isn't
  available (as under QEMU) shows as "--".

## Demo: `mandel.asm`

Four 64-bit doubles per YMM register, two registers interleaved per step to
hide FMA latency, so 8 pixels per inner iteration. `vcmppd` builds the escape
mask, `vpsubq` counts iterations in each lane, and `vtestpd` leaves as soon as
all 8 have escaped. Rows are jobs. The zoom heads into the seahorse valley at
0.965× per frame, with the iteration limit rising from 192 to 4096, and
restarts before double precision runs out.

## Power: `power.asm`

Reboot and power-off use UEFI `ResetSystem` first. Fallbacks: the ACPI reset
register, port CF9, the 8042 and a triple fault for reboot; ACPI S5 (SLP_TYP
from `_S5_`) for power-off, then QEMU's port 0x604.

## Conventions

- System V-like: arguments in RDI, RSI, RDX, RCX, R8, R9; result in RAX;
  RBX, RBP, R12 to R15 preserved. Many leaf helpers preserve more, and say so
  in their header comment.
- `KLOG "fmt", args...` logs to serial and, once the console exists, to the
  screen; `SPRINTF buf, "fmt", args...` formats into memory. Arguments are
  64-bit registers, immediates or `qword [mem]`.
- Structures are `equ` offsets (`PC_*`, `PE_*`, `XC_*`, `DV_*`, `NV_*`,
  `DK_*`, `VO_*`, `VF_*`).
- Self-contained modules are also tested on the host: `tools/test/<module>/`
  assembles the module with a small shim and drives it from C or Python.
