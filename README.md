# Axiom

An operating system written entirely in x86-64 assembly, booting straight from
UEFI onto the hardware that is actually present. No C, no libc, no GRUB, no
borrowed kernel: about seventy-three thousand lines of NASM, top to bottom.

Why it exists and where it is going: [docs/VISION.md](docs/VISION.md).
How it works: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## M0 "First light": what it does today

- Boots as a UEFI application and picks the display's largest mode, up to 4K.
  Anti-aliased text in a font sized for the screen (10×20, 15×30 or 20×40).
- Brings **every hardware thread** online in parallel (28 on an i7-14700F),
  sorted into P-cores, E-cores and SMT siblings.
- Live per-thread telemetry: clock (APERF/MPERF), temperature (digital thermal
  sensor) and package power (RAPL).
- A Mandelbrot zoom in AVX2 + FMA running on all cores at once, with a
  one-core-versus-all benchmark.
- **A desktop of windows**, light or dark (`theme`), with an accent colour
  and a scale: a menu bar with the app in front, the time and what the
  machine is doing; a frosted dock of apps, their running dots, and
  pictures of minimised windows; windows with round corners and soft
  shadows, in Noto Sans. System, Processors, the Mandelbrot and each shell
  are windows, dragged by their title bars, resized from any edge, raised
  and given the keys by a click, closed, minimised into the dock and zoomed
  by their three buttons (or a double click on the title bar). Terminal in
  the dock (or `shell`) opens another shell, each with its own output,
  scroll-back (the wheel), history and commands running; what a command
  prints later goes to the shell it was typed in. `win` lists the windows
  and moves, sizes, raises, minimises, zooms or closes one. **Programs open
  windows of their own**,
  by capability: pixels they draw into, keys, clicks, drags and the wheel
  as messages over a channel, and a title; `paint` is one to draw in.
  Their windows can resize, and draw in the desktop's own look: its
  colours, its scale and its fonts, shared with them (`src/user/kit.inc`).
- **Notes**, `notes [file ...]`: a text and code editor in tabs. Line
  numbers, the current line marked, colours for assembly, C and its kin,
  Python, shell and settings files, JSON and Markdown; find and replace in a
  bar, go to a line, undo and redo, the clipboard, indenting, comments on
  and off, lines moved and copied, the text larger or smaller; Open and
  Save As sheets that browse the volumes and make folders, and asking
  before closing what was not saved. Files come by capability: a program
  given `AW_FILES` (or `+files`) reaches the FAT volumes through a handle,
  or one folder of them through a handle made from it, and writes only a
  volume the user made writable.
- **Files**, `files [folder]` (or Files in the dock): the volumes laid out
  as Finder lays them out. The volumes at the left; back, forward, the
  folder's name, icons or a list and a search at the top; icons for
  folders, pages with a badge of what they hold and program tiles, or a
  list with when each was written, its size and its kind, sorted by any of
  them; the path at the bottom, each part a way back. A folder opens in
  place; a text file opens in Notes, which is handed that folder alone and
  nothing more; space looks at a file without opening it. Things are made,
  renamed, duplicated, copied, moved and deleted (a folder and all it
  holds, once asked) with Finder's keys or a right click, and only on a
  volume the user made writable: Files says how, never does it itself.
- **A web browser**, `browse [url]`: HTML and plain text over HTTP and
  HTTPS in a window of its own, laid out and drawn with anti-aliased
  DejaVu text (headings, bold, italic, monospace, lists, quotes, tables,
  links), back, forward, reload and an address bar, scrolled by the wheel,
  the keys or its scrollbar; links clicked, redirects followed, `#anchors`
  scrolled to. No CSS, images or scripts yet.
- **USB** on every xHCI controller: hubs (nested, USB 2 and 3), hot-plug, and a
  HID report parser for keyboards (6-key and N-key rollover), mice and tablets.
  A mouse cursor: in the Mandelbrot's window, click to recentre it, wheel to
  zoom, right click to hold, middle click to start over.
- **NVMe SSDs**, an I/O queue pair per CPU, each completing on its own CPU's
  interrupt (`nvme`, `nvme test`), and **USB sticks** (hot-plug too), GPT and
  MBR partitions, and
  **FAT32** with long names: read, write, copy, make directories, remove.
  Every volume is read-only until you unlock it with `vol <n> rw`.
- **DMA confined by VT-d**: each driver's devices reach only the memory that
  driver mapped for them (an NVMe command's buffer only while it is out), and
  a device no driver claims reaches none (`iommu`, `iommu test`).
- **An object store** on NVMe: content-addressed (SHA-256) and copy-on-write,
  every change staged in a transaction, shown by `store diff`, and committed
  with who made it, through which capability, when and why (`store log`).
  Snapshots, rollback and undo, each a new commit, so nothing is lost; a
  crash mid-commit leaves the store as it was (`store tear` shows it).
  Programs reach it only through a capability on names of their own.
  It writes to QEMU's test drive alone; any other store is read-only.
- **Ethernet** on Realtek RTL8111/8168 chips (the Victus's): DHCP, ARP, IPv4,
  ICMP, UDP, DNS and **TCP**. `ping` and `host` work by name, and `http`
  fetches a web page over HTTP/1.1 (chunked bodies, the connection kept for
  the next request), over **TLS 1.3** for `https://`, or saves it to a file;
  `httpd <port>` serves the current volume, read only, to browsers.
  **IPv6** beside IPv4: a link-local address, a global one from the
  router's advertisements (SLAAC), NDP, ICMPv6, AAAA lookups; `ping`,
  `http` (`http://[2001:db8::1]:8080/`), `httpd`, TCP and sockets work over
  either.
  The server's certificate chain is checked against 136 built-in trusted
  roots, its name and dates too; `http -k` fetches without checking, and
  says so.
- **Claude**, from the prompt: `ask <question>` sends it to the Messages API
  over that https and shows the answer as it is written, word-wrapped, the
  conversation kept until `claude new`. The API key is typed once
  (`claude key ...`, shown as stars and never logged) or read from
  `CLAUDE.KEY` on the boot stick.
- **TLS 1.3**, written here: SHA-256 on the SHA extensions, HMAC, HKDF,
  AES-128-GCM on AES-NI and PCLMULQDQ, X25519, keys from RDSEED, the
  client handshake, and certificates: X.509, SHA-384/512, RSA (PKCS #1 v1.5
  and PSS) and ECDSA on P-256 and P-384. The crypto is checked against the published vectors at
  every boot; `crypto` repeats the check and times each.
- **A shell of its own** over a USB keyboard, a PS/2 keyboard or the serial
  port. A command is a thing, then an action: `files`, `files show
  notes.txt`, `files copy a.txt b.txt`, `files move b.txt old/`, `files new
  old/`, `files remove old`, `files find *.axe`, `go /`, `here`; `help files`
  lists what a thing does. What a command gives is a table of records, not
  text, and a `|` hands it to a stage that works on its fields: `where size
  > 10K`, `sort size down`, `pick name size`, `first 3`, `last 3`, `count`,
  `to text`, `to json`. `files /EFI/AXIOM | sort size down | first 3` and
  `threads | where pinned = yes | count` mean what they say; text comes only
  at the end, on the screen or into a file (`> list.txt`, `>> list.txt`).
  Quotes, `*` and `?`, `$name` (from `set name value`), `;`, `&&` and `||`
  work as written. `cpus`, `mem`, `threads` and `tasks` (`tasks stop <id>`)
  are records too; the rest (`info objects rings run user win shell pci
  acpi iommu usb disks nvme store vol date net ip ip6 dhcp ping host arp
  http httpd ask claude tcp crypto log demo bench uptime echo clear panic
  reboot poweroff`) print as before, and a `|` takes what they print as
  lines.
- **A log on the boot stick**: everything Axiom prints, the commands typed
  and any panic report go into `AXIOM.LOG` on the USB stick it booted from,
  readable from Windows afterwards.
- **Memory of its own**: the kernel builds its own page tables at boot, with
  nothing mapped in the lower half (a null pointer faults), no page both
  writable and executable, and a guard page under every stack. A vm region
  for stacks, device memory and large blocks, TLB shootdowns across every
  CPU, and a heap (`kmalloc`, `kfree`) that catches double frees and writes
  after free. A fault report says what the access ran into: `a write to
  ..., which is read-only: kernel code`, `the guard page below CPU 3's
  kernel stack (a stack overflow)`. `mem test` runs it all hard on every
  CPU; `panic <kind>` makes each fault on purpose.
- **Threads and a scheduler** that knows P-cores from E-cores: kernel
  threads on guarded stacks with their SIMD state saved, a run queue per
  CPU ordered by CPU time had, 4 ms slices, sleeps to the microsecond, and
  placement by class (perf threads on P-cores, eff threads on E-cores),
  with idle CPUs stealing work and threads moving to the right kind of core
  when one frees up. The main loop is the first thread, and a key still
  answers at once with every CPU busy. `threads` shows each thread and
  `threads cpus` each CPU;
  `threads test` checks it all; `threads spin 16 perf` puts load on.
- **Kernel objects and capabilities**: tasks, threads, events and blocks of
  memory are typed objects, and a task reaches them only through handles in
  its own table. A handle carries rights, an expiry and, for memory, a
  window; derived ones have fewer, can be given to another task, and are
  taken back wherever they went by revoking the one they came from. Every
  change and every refusal goes into an audit ring. `objects` shows each
  type and task, `objects <task>` its handles, `objects audit` the ring, and
  `objects test` checks it all.
- **Async rings**: a task asks for many things at once through a submission
  and a completion queue in memory it shares with the kernel, one call for
  any number of them. Waiting for an event, a thread or a time blocks
  nothing: the completion is written when it happens, from whatever made it
  happen. Entries can be linked into chains and canceled, and a full
  completion queue holds entries back rather than losing one. `rings` shows
  each ring and what waits; `rings test` checks it all.
- **Programs in ring 3**: a program's name (`hello`, `spin 3 &`) loads
  `/EFI/AXIOM/<PROGRAM>.AXE` from the boot stick into a task with page
  tables of its own (code read-only, data not executable, a guarded stack)
  and runs it on any CPU. A program reaches the kernel by `SYSCALL`, and
  for most things through its ring, the console included. Programs start
  programs and hand them a handle, talk over channels (messages between
  tasks, waited for on the ring), and map and unmap memory; a mapping goes
  when its handle is closed, revoked or given away. A fault in a program
  ends that program, says what it ran into, and nothing else notices;
  killing one (ctrl+C, or a program killing its child) ends every program
  it started too. Several run at once (`&`, `tasks stop <program>`), and
  each gets only the capabilities it declares (the network, the store, the
  desktop) or is granted for that run (`+net hello`). `hello`, `test`, `child`, `fault`, `spin`, `stash`, `paint`, `browse`, `notes`, `files` and `fstest` come with it
  (`src/user/`); `user test` runs them all, with a fault of every kind.
- **Linux programs, unchanged**: `linux <program> [arguments]` runs an
  x86-64 Linux program from a root on the boot stick (`tools/mkroot.py`
  copies programs and the libraries they need from WSL; `tools/mkstick.py
  --linux build/linux` puts it at `/LINUX`): its ELF file and ld.so mapped
  as Linux would, glibc's system calls answered by Axiom's own (memory
  filled in on demand and shared with the file cache, a read-only view of
  the root, the clocks, `uname`, the ids, threads, futexes and signals with
  handlers, `fork`, `execve`, `wait4`, pipes, process groups), and a
  terminal that speaks xterm: termios, the window's size, keys as xterm
  sends them, colours, the alternate screen, answers to a program's
  questions. Ubuntu's bash (interactive, with job control and readline),
  dash, `ls -la`, `cat`, `grep`, `sort`, `xargs`, `date`, `sha256sum`,
  `stty`, `less` and others run, and programs using pthreads; ctrl+C sends
  SIGINT. The network and Claude Code itself come next (see
  `docs/VISION.md`).
- **Programs in Rust, natively** (`sdk/rust`): the `axiom` crate is the
  system interface for Rust (the ring, windows and their events, files,
  the clock, a heap), and a program built with it is an `.AXE` like any
  other, through no Linux layer. With std too: the target is std's zkvm
  layer, whose few system calls the crate supplies, so `println!`, `Vec`,
  `HashMap` and the rest work. `rhello` and `rdemo` come with it; `python
  tools/rust.py` builds them (rustup's nightly with rust-src, offline).
- ACPI (MADT, MCFG, FADT, the DSDT's `_S5_`), SMBIOS, PCI Express enumeration,
  x2APIC (falling back to xAPIC), I/O APIC, TSC-deadline timer, and a panic
  screen that stops every other CPU.

## Build

Needs [NASM](https://nasm.us) 2.15+ and Python 3 on the PATH.

```bash
python tools/build.py
```

That writes `build/esp/EFI/BOOT/BOOTX64.EFI` (about 500 KB, the kernel is
embedded inside it), and the programs, `build/esp/EFI/AXIOM/*.AXE`. `python tools/build.py --max 1920x1080` caps the display
mode if you'd rather have bigger text. The kernel and the programs are
assembled side by side, and only what changed (or includes a file that
changed) is assembled again; `--all` assembles everything. The kernel's
jumps are left long (`-O1`): sizing each (`-Ox`, `--small`) takes NASM
some 200 passes, a minute, for a kernel 4% smaller.

The Rust programs (`sdk/rust`) are built apart, with rustup's nightly
toolchain and its `rust-src`, nothing downloaded: `python tools/rust.py`
writes `RHELLO.AXE` and `RDEMO.AXE` beside the others. See
`sdk/rust/README.md`.

## Run in QEMU

```bash
python tools/run.py
```

q35 machine, OVMF firmware, 8 threads, 6 GiB. Useful variants:

```bash
python tools/run.py --smp 28 --extra "-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0"
```

```bash
python tools/run.py --headless --keys "cpus\n" --shot build/shot.png
```

QEMU runs on the Windows Hypervisor Platform (WHPX) when it is there: the
first run tries it and remembers the answer in `build/accel.txt` (delete that
to ask again; `--accel tcg` forces QEMU's own CPU emulation). WHPX needs
Windows' "Windows Hypervisor Platform" feature. Under WHPX the guest gets
`-cpu max,-svm,-vmx`, which still has SHA-NI, AES-NI and RDSEED; the firmware
faults on plain `max` there. Under TCG one Mandelbrot frame takes seconds
and the shell answers between frames, so type `demo` to stop the zoom.
Headless runs start without it (`-smbios type=11,value=axiom.demo=off`, an
OEM string Axiom reads at boot), since it keeps every CPU busy; `--demo`
starts it anyway.

Headless runs wait for the shell's first prompt line instead of a fixed time,
and `until TEXT` in `--script` waits for TEXT to appear in the log after the
last text typed. `type TEXT` sends TEXT down the serial port all at once, as
a terminal would; `press TEXT` types it on the keyboard, key by key. `abs X Y [button]`,
`drag X1 Y1 X2 Y2` and `wheel X Y N` work a USB tablet (QEMU's 0..32767 on
each axis; add it with `--extra "-device qemu-xhci,id=ux -device
usb-tablet,bus=ux.0"`), as `tools/test/desk` does. With
`--port 0` a run takes ports nobody uses and firmware variables of its own,
so several can boot side by side. A scripted check that used to sleep
through a minute takes a few seconds:

```bash
python tools/run.py --headless --nic rtl8139 --keys "crypto\n" --script "until X25519; type http https://example.com/\n; until HTTP/; type poweroff\n"
```

Every test suite, side by side, after a build (about a minute and a half on
the Victus when nothing else is busy; `--quick` skips the TCG boots, and
naming suites runs only those):

```bash
python tools/test/all.py
```

Their QEMU boots share the host's idle threads (`tools/test/qemu.py`), so
the timings the guests measure stay honest; a boot that mostly waits (the
shell, the browser, the network suites) takes one slot whatever its vCPUs,
since an idle guest's CPUs sleep. Each suite also runs alone, as
`python tools/test/<suite>/run.py`.

A test disk for the storage code: `tools/mkdisk.py` builds `build/disk.img`
(GPT, a 64 MiB FAT32 partition full of test files, a blank one), and
`tools/fatcheck.py` checks it afterwards (chains, long names, both FATs, lost
clusters) and prints files.

```bash
python tools/mkdisk.py
```

```bash
python tools/run.py --extra "-drive file=build/disk.img,if=none,id=nvm,format=raw -device nvme,serial=axiom0,drive=nvm"
```

```bash
python tools/fatcheck.py --tree
```

The same image as a USB stick, plugged in after boot behind a hub
(`--script` runs monitor commands; `type` types into Axiom):

```bash
python tools/run.py --headless --extra "-device qemu-xhci,id=xhci -device usb-hub,bus=xhci.0,port=1 -drive file=build/disk.img,if=none,id=stick,format=raw" --script "device_add usb-storage,bus=xhci.0,port=1.2,drive=stick,id=st1; wait 3; type disks\n; until vol"
```

The loader on a real USB stick, as on the Victus: `tools/mkstick.py` puts
`build/esp` on a GPT + FAT32 image, `--stick` boots it, and the log lands in
its `AXIOM.LOG` (Git Bash: prefix the last command with `MSYS_NO_PATHCONV=1`):

```bash
python tools/mkstick.py
```

```bash
python tools/run.py --stick build/stick.img
```

```bash
python tools/fatcheck.py build/stick.img --show /AXIOM.LOG
```

QEMU has no RTL8168, but its RTL8139C+ shares the descriptor rings, so the
same driver runs there. On QEMU's user network DHCP gives 10.0.2.15, the
gateway 10.0.2.2 answers pings and 10.0.2.3 answers DNS. Every frame also
lands in `build/net-4444.pcap`:

```bash
python tools/run.py --nic rtl8139
```

There, `http example.com` fetches through QEMU to the internet, and
`http 10.0.2.2:8000/` reaches a server on your own machine (for instance
`python -m http.server 8000 --bind 127.0.0.1`); `python tools/httpsd.py`
serves `https://10.0.2.2:8443/` the same way, and `python tools/claudemock.py`
stands in for the Claude API at `https://10.0.2.2:8444` (`claude server
https://10.0.2.2:8444 -k`, then the key it prints). To see TCP cope with a bad
network, `tools/netpeer.py` plays a server at 10.1.0.1 that loses, reorders,
refuses and resets on purpose (its docstring lists the ports); start it,
then boot with `--netdev "socket,connect=127.0.0.1:5555"`, set
`ip 10.1.0.2/24`, and fetch `http 10.1.0.1/big`:

```bash
python tools/netpeer.py
```

Two copies of Axiom on one wire (`ip 10.1.0.1/24` in one, `ip 10.1.0.2/24`
in the other, then `ping`):

```bash
python tools/run.py --nic rtl8139 --netdev "socket,listen=127.0.0.1:5555"
```

```bash
python tools/run.py --nic rtl8139 --netdev "socket,connect=127.0.0.1:5555" --mac 52:54:00:12:34:57 --port 4450
```

## Boot it on real hardware

Tested target: HP Victus 15L (i7-14700F, 64 GB, RTX 4060 Ti), AMI UEFI.

1. Format a USB stick as **FAT32**. Windows' format dialog offers FAT32 only
   for sticks up to 32 GB; for a bigger one, make a 32 GB partition first
   (Disk Management) or use a tool such as Rufus.
2. Copy `build/esp/EFI` to the root of the stick, so that the stick contains
   `\EFI\BOOT\BOOTX64.EFI` (and the programs, in `\EFI\AXIOM`).
3. Make sure **Secure Boot is off** in the firmware setup (Axiom isn't signed).
   On the Victus it already is.
4. Plug in the stick, power on and tap **F9** for the boot menu. Pick the USB
   stick (the "UEFI" entry).
5. The desktop should appear within a second. Type `help` on the keyboard.

Axiom reads the boot stick and the NVMe drive (`disks`, `files`, `files show`) and
starts on the stick's volume, but writes nothing until you unlock a volume
with `vol <n> rw`, with one exception: its log, `AXIOM.LOG` in the root of
the stick it booted from, saved every 10 seconds while it grows, before
`reboot` or `poweroff`, and after a crash. Back in Windows, open it from the
stick. `log off` stops that; no other volume and no other file is ever
touched by it. Unlock the **stick's** volume (`disks` shows which one is
`USB`) to save files there. On the Victus the NVMe drive holds Windows: its
EFI partition is FAT32, and Windows needs the files on it to boot, so leave
it read-only. Run `vol` before writing to see which volume is current, and
wait for the prompt before pulling the stick. Power off with `poweroff`, or
`reboot` to go back to Windows.

Things worth knowing:

- **The demo loads every core with AVX2.** Expect fans and package power to
  climb to the CPU's limits, as under any all-core benchmark. `demo` toggles it.
- `threads cpus` shows each CPU's kind and load, `threads` every thread.
  `threads spin 16 perf` runs 16 perf threads for 5 seconds, which should
  land on the 16 P-core threads; each reports, when it ends, how much of its
  time it had on P-cores. `threads spin 12 eff` does the same for E-cores.
- With an Ethernet cable in, Axiom asks DHCP for an address within a few
  seconds; `net` shows the link and address, `ping 1.1.1.1` or
  `ping example.com` tries the way out, `http example.com` fetches a page,
  ctrl+C stops any of them.
- To talk to Claude, put your API key (from console.anthropic.com) in a file
  `CLAUDE.KEY` at the top of the stick, or type `claude key <key>` once
  booted; then `ask <question>`. The file is plain text on the stick, so keep
  the stick to yourself, or type the key instead. Each question is billed to
  that key; `claude model <name>` picks a cheaper model.
- `run hello` runs a program in ring 3; `user test` checks ring 3 on every
  CPU, faults included, and `run spin 28` puts a thread on each one until
  ctrl+C.
- Keyboards and mice work directly or through hubs (the Keychron's receiver
  included). Bluetooth isn't supported yet, so a Bluetooth-only mouse won't
  move the cursor.
- If the screen stays black, check that CSM / legacy boot is disabled in the
  firmware setup, so the graphics card runs its UEFI firmware (GOP). The
  i7-14700F has no integrated graphics, so the monitor must be on the RTX card.
- Serial output (COM1, 115200) mirrors the log, if your machine has a header.

## Layout

```
src/boot/uefi.asm       the loader: a hand-built PE32+ UEFI application
src/kernel/*.asm        the kernel, one flat image at 0xFFFFFFFF80000000
src/user/               programs for ring 3 (axe.inc: their header and runtime)
src/include/            structures shared by the two
sdk/rust/               programs in Rust: the axiom crate, the target, two programs
tools/rust.py           build them; tools/mkaxe.py turns each into an .AXE
tools/build.py          assemble everything
tools/run.py            boot in QEMU; type keys, move the pointer, take screenshots
tools/mkdisk.py         a GPT + FAT32 test disk (as an NVMe drive or a USB stick)
tools/mkstick.py        a bootable stick image with build/esp on it (and,
                        with --linux, a Linux root at /LINUX)
tools/mkroot.py         a Linux root, build/linux, from WSL's programs
tools/netpeer.py        an unreliable network peer, to test TCP against
tools/httpsd.py         a local HTTPS server (TLS 1.3), to test https against
tools/claudemock.py     a stand-in for the Claude Messages API, to test ask against
tools/fatcheck.py       check that disk after Axiom has written to it
tools/mkroots.py        the trusted roots, src/kernel/gen/roots.asm, from
                        certifi's copy of Mozilla's list
tools/test/             host-side tests for self-contained modules (tls: the
                        crypto; tlsclient: the TLS client against OpenSSL;
                        pki: certificates and signatures; heap: kmalloc and
                        kfree, from four threads at once) and QEMU suites
                        (claude: ask, against claudemock.py; memory: the
                        page tables, W^X, guard pages, the vm region and
                        the heap, and each kind of fault; threads: the
                        scheduler on 8 CPUs, on one, and under TCG;
                        objects: handles and capabilities, likewise;
                        rings: async rings, likewise; user: ring 3,
                        from a stick image, likewise; nvme: per-CPU
                        queues on QEMU's NVMe drive, with 1 to 8 CPUs and
                        fewer queues than CPUs; iommu: VT-d, a device
                        kept out of memory not its own; store: the object
                        store, its drive read back by a reader of its own,
                        torn, remounted, damaged and read-only; tcp: the
                        server side and its window, through 'tcp echo',
                        from clients on the host; net: sockets for ring
                        3, through NET.AXE, against servers, a DNS
                        server and clients on the host; http: the HTTP/1.1
                        client against servers on the host, and httpd
                        against clients there; ip6: IPv6 on QEMU's
                        network, and between two guests on a hub that is
                        their router; linux: Linux programs from
                        Ubuntu, and threads and signals in C, from a
                        stick with a root on it; rust: the Rust programs,
                        their heap, files, a window and its events); all.py
                        runs them
                        all at once, and qemu.py boots side by side
tools/mkfont.py         rasterize the console font into src/kernel/gen/
tools/mkuifont.py       rasterize the desktop's font into src/kernel/gen/
docs/                   vision and architecture
```

## License notes

The console font is rasterized from **Cascadia Mono**, © Microsoft Corporation,
licensed under the [SIL Open Font License 1.1](https://openfontlicense.org).
The bitmaps in `src/kernel/gen/` are a derivative of it and carry the same
license. `tools/mkfont.py` regenerates them from any TrueType font you prefer.

The desktop's font (`uifont.*` in `src/kernel/gen/`) is rasterized from
**Noto Sans**, © Google LLC, under the [SIL Open Font License 1.1](https://openfontlicense.org),
with a few symbols from **DejaVu Sans** (Bitstream Vera license, and public
domain changes). `tools/mkuifont.py` regenerates it.

The trusted roots in `src/kernel/gen/roots.asm` are the public keys and names
of the certificate authorities in Mozilla's root store, taken from
[certifi](https://github.com/certifi/python-certifi) (2026.01.04), which
distributes it under the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).
`tools/mkroots.py` regenerates them from certifi or any PEM bundle.
