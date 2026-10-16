# Axiom

An operating system written entirely in x86-64 assembly, booting straight from
UEFI onto the hardware that is actually present. No C, no libc, no GRUB, no
borrowed kernel: about thirty-nine thousand lines of NASM, top to bottom.

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
- **USB** on every xHCI controller: hubs (nested, USB 2 and 3), hot-plug, and a
  HID report parser for keyboards (6-key and N-key rollover), mice and tablets.
  A mouse cursor: click to recentre the Mandelbrot, wheel to zoom, right click
  to hold, middle click to start over.
- **NVMe SSDs** and **USB sticks** (hot-plug too), GPT and MBR partitions, and
  **FAT32** with long names: read, write, copy, make directories, remove.
  Every volume is read-only until you unlock it with `vol <n> rw`.
- **Ethernet** on Realtek RTL8111/8168 chips (the Victus's): DHCP, ARP, IPv4,
  ICMP, UDP, DNS and **TCP**. `ping` and `host` work by name, and `http`
  fetches a web page, over **TLS 1.3** for `https://`, or saves it to a file.
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
- A shell over a USB keyboard, a PS/2 keyboard or the serial port. Commands:
  `help info cpus mem pci acpi usb disks vol ls cd cat cp write mkdir rm date
  net ip dhcp ping host arp http ask claude tcp crypto log demo bench uptime
  echo clear panic reboot poweroff`.
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
- ACPI (MADT, MCFG, FADT, the DSDT's `_S5_`), SMBIOS, PCI Express enumeration,
  x2APIC (falling back to xAPIC), I/O APIC, TSC-deadline timer, and a panic
  screen that stops every other CPU.

## Build

Needs [NASM](https://nasm.us) 2.15+ and Python 3 on the PATH.

```bash
python tools/build.py
```

That writes `build/esp/EFI/BOOT/BOOTX64.EFI` (about 280 KB, the kernel is
embedded inside it). `python tools/build.py --max 1920x1080` caps the display
mode if you'd rather have bigger text.

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

Headless runs wait for the shell's first prompt line instead of a fixed time,
and `until TEXT` in `--script` waits for TEXT to appear in the log after the
last keys typed. A scripted check that used to sleep through a minute takes
a few seconds:

```bash
python tools/run.py --headless --nic rtl8139 --keys "crypto\n" --script "until X25519; type http https://example.com/\n; until HTTP/; type poweroff\n"
```

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
   `\EFI\BOOT\BOOTX64.EFI`.
3. Make sure **Secure Boot is off** in the firmware setup (Axiom isn't signed).
   On the Victus it already is.
4. Plug in the stick, power on and tap **F9** for the boot menu. Pick the USB
   stick (the "UEFI" entry).
5. The dashboard should appear within a second. Type `help` on the keyboard.

Axiom reads the boot stick and the NVMe drive (`disks`, `ls`, `cat`) and
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
- With an Ethernet cable in, Axiom asks DHCP for an address within a few
  seconds; `net` shows the link and address, `ping 1.1.1.1` or
  `ping example.com` tries the way out, `http example.com` fetches a page,
  ctrl+C stops any of them.
- To talk to Claude, put your API key (from console.anthropic.com) in a file
  `CLAUDE.KEY` at the top of the stick, or type `claude key <key>` once
  booted; then `ask <question>`. The file is plain text on the stick, so keep
  the stick to yourself, or type the key instead. Each question is billed to
  that key; `claude model <name>` picks a cheaper model.
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
src/include/            structures shared by the two
tools/build.py          assemble everything
tools/run.py            boot in QEMU; type keys, move the pointer, take screenshots
tools/mkdisk.py         a GPT + FAT32 test disk (as an NVMe drive or a USB stick)
tools/mkstick.py        a bootable stick image with build/esp on it
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
                        the heap, and each kind of fault)
tools/mkfont.py         rasterize the console font into src/kernel/gen/
docs/                   vision and architecture
```

## License notes

The console font is rasterized from **Cascadia Mono**, © Microsoft Corporation,
licensed under the [SIL Open Font License 1.1](https://openfontlicense.org).
The bitmaps in `src/kernel/gen/` are a derivative of it and carry the same
license. `tools/mkfont.py` regenerates them from any TrueType font you prefer.

The trusted roots in `src/kernel/gen/roots.asm` are the public keys and names
of the certificate authorities in Mozilla's root store, taken from
[certifi](https://github.com/certifi/python-certifi) (2026.01.04), which
distributes it under the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).
`tools/mkroots.py` regenerates them from certifi or any PEM bundle.
