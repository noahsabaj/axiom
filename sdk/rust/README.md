# Rust on Axiom

Axiom's programs can be written in Rust, natively: the program is an
ordinary `.AXE`, run from the shell or the dock like any other, talking to
the kernel through its ring. Nothing passes through the Linux layer.

```
sdk/rust/
  x86_64-axiom.json   the target
  axiom/              the crate: the system interface, a heap, threads, std's layer
  axiom/axiom.ld      the layout of an .AXE (its header made by the linker)
  hello/              rhello: no std; the console, the heap, files, the clock
  demo/               rdemo: std; a window, drawn each frame, and its events
  tone/               rtone: no std; a sine through a stream of sound
  std/                rstd: std's threads, locks, thread_local!, time, files
tools/rust.py         builds them into build/esp/EFI/AXIOM/<NAME>.AXE
tools/mkaxe.py        an ELF linked by axiom.ld -> an .AXE
tools/test/rust/      runs rhello, rdemo and rstd in QEMU (tools/test/sound: rtone)
```

## Building

Needs rustup's nightly toolchain with `rust-src`. Nothing is downloaded:

```
python tools/rust.py               # every program here
python tools/rust.py rdemo         # one
```

What that runs, for a program of your own elsewhere:

```
cargo +nightly build --release --offline \
  -Zbuild-std=std,panic_abort -Zbuild-std-features=compiler-builtins-mem \
  -Zjson-target-spec --target sdk/rust/x86_64-axiom.json \
  --config 'source.crates-io.replace-with="rust-src"' \
  --config 'source.rust-src.directory="<sysroot>/lib/rustlib/src/rust/library/vendor"'
python tools/mkaxe.py target/x86_64-axiom/release/NAME NAME.AXE
```

The two `--config`s take the crates std is built from out of rust-src's own
copies, offline. A program with crates.io dependencies of its own leaves
them out, and gets them from the registry.

**The target says `os: "hermit"`, `vendor: "axiom"`.** std has no layer
for an operating system it does not know (an unknown `os` does not
compile), but its layer for Hermit, a small kernel, is a set of `extern
"C"` functions (`sys_write`, `sys_spawn2`, `sys_futex_wait`, `sys_open`,
`sys_clock_gettime`, ...), which the `axiom` crate supplies on Axiom's own
calls (`axiom::hermit`). Nothing of Hermit itself is in a program. To tell
Axiom apart in `cfg`: `target_os = "hermit"` with `target_vendor = "axiom"`.

What std has on Axiom:

- **`println!`, `std::env::args()`**, `HashMap` seeded by RDRAND, and all
  of `alloc` and `core`. The heap is `axiom::Heap`: no `#[global_allocator]`
  needed.
- **Threads**: `std::thread::spawn` (2 MiB stacks unless a `Builder` says),
  `scope`, names, `park` and `unpark`, `available_parallelism()` (the CPUs
  running). Each thread has its own ring, made the first time it needs one.
- **`std::sync`**: `Mutex`, `RwLock`, `Condvar` (with timeouts), `Once`,
  `OnceLock`, `Barrier`, `mpsc`, atomics, all on the kernel's
  futexes.
- **`thread_local!`**, with destructors: FS's base, set for each thread.
- **Time**: `Instant` (the TSC), `SystemTime` (the RTC's, as UTC),
  `thread::sleep`.
- **`std::fs`**: `File` (read, write, append, seek, `metadata`),
  `read`, `write`, `read_to_string`, `create_dir`, `read_dir`, `metadata`,
  `remove_file`, `remove_dir`. Paths are `vol<n>:/a/b`, or `/a/b` on the
  volume Axiom booted from; `.` and `..` are taken out. A file is read
  whole when opened and written whole when closed (16 MiB at most), so
  close it (drop it) to write it. A volume the user hasn't made writable
  is `Read-only file system`, when the file is opened, except in `/Home`
  on the boot volume, which programs may always write: keep a program's
  files there (`HOME` is `/Home`). The program wants `wants::FILES`.
- **`std::net`**: `TcpStream` (`connect`, `connect_timeout`, read and
  write timeouts, `peek`, `set_nonblocking`, `shutdown`, `try_clone`,
  `peer_addr`, `local_addr`) and `TcpListener` (a port, or 0 for one of
  ours; `accept`), over the kernel's sockets, 64 KiB each way. Names are
  looked up by the kernel's DNS, one address each; connecting to a name's
  address gives the kernel the name, so a capability to that host reaches
  it. There is no loopback (binding or connecting to 127.0.0.1 says so)
  and no UDP. The program wants `wants::NET`. TLS is `axiom::net`'s
  (`Net::connect` with `Tls::Checked`), outside std, and so is its
  server side: `Net::listen_tls` with an `Identity` (a P-256 key and its
  certificates, `Identity::from_pem` from a cert.pem and a key.pem, PKCS
  #8 or SEC1).
- **`std::process::exit`** ends the program, every thread, with its code.
  A panic aborts: the program ends, 134. There is no unwinding.

Not there yet: UDP, `std::process::Command`, and `read_dir` of an empty
folder, which is an error.

## A program

```rust
axiom::entry!(wants = axiom::wants::DESK | axiom::wants::FILES);

fn main() -> axiom::Result<()> {
    let mut w = axiom::Window::open(800, 600, axiom::Window::RESIZE)?;
    w.set_title("Hello");
    loop {
        let next = axiom::Instant::now() + core::time::Duration::from_millis(16);
        while let Some(e) = w.wait(Some(next)) {
            if matches!(e, axiom::Event::Close | axiom::Event::Gone) {
                return Ok(());
            }
        }
        let mut f = w.frame();                 // f.row(y)[x] = 0x00RRGGBB
        f.fill(0x203040);
        w.show();
    }
}
```

`entry!` makes `_start`: the start block read, an 8 MiB stack of its own
(`entry!(wants = ..., stack = 16 << 20)` for another size), then std's own
start, which runs `main` as anywhere: what it returns is the program's
exit (`()`, an `ExitCode`, or a `Result`, whose error is said). `wants` is
what the shell gives it, and no more (`wants::NET`, `STORE`, `DESK`,
`FILES`, `SOUND`; `+desk` and the like give more for one run).

Without std, the program names its `main` and says the rest itself:

```rust
#![no_std]
#![no_main]

#[global_allocator]
static HEAP: axiom::Heap = axiom::Heap::new();

axiom::entry!(main, wants = axiom::wants::FILES);
axiom::panic_handler!();

fn main() -> axiom::Result<()> { /* ... */ Ok(()) }
```

`main` returns `()`, an integer, or a `Result`.

## The crate

- **`axiom::Window`**: `open(w, h, flags)` (pixels; `Window::RESIZE`, the
  user may resize it; `Window::FULL`, resizable and zoomed to begin with,
  filling the screen between the menu bar and the dock; `Window::KEYS` and
  `Window::HOVER`, for games, below),
  `size()`, `stride()`, `pixels()` / `frame()`, `show()` / `show_rect()`,
  `set_title()`, `poll()` (does not wait) and `wait(deadline)`.
  - The pixels are memory the program and the desktop share: a `u32` each,
    `0x00RRGGBB` (bytes B, G, R, x).
  - **The stride**, in `u32`s: the screen's width for a window that can be
    resized (or is the whole screen), which has room for the whole screen
    from the start; its own width for one that cannot. It never changes.
  - **A resize hands it no new memory**: `Event::Resized { width, height }`
    says its size now; draw all of it again, then `show()`.
  - What was drawn reaches the screen once shown.
  - Events (`axiom::Event`): `Key { key, mods, code }` while it has the
    keys (as text: a press and its repeats), `Press` and `Release`
    (`Button::Left`, `Right`, `Middle`, at x, y in the window), `Move { x,
    y, dx, dy }` (while a button is held), `Wheel { notches }`, `Close`
    (its close button: it only asks), `Resized`, `Look` (the theme or the
    scale changed), `Focus(bool)`, and `Gone`.
  - For games: with `Window::KEYS`, `KeyDown { usage, mods }` and `KeyUp`
    as well, once each way however long a key is held, by its USB HID usage
    (`axiom::window::usage`: where the key is, whatever it types), from a
    USB or a PS/2 keyboard alike. A key pressed before the window had the
    keys may come up without going down; `Focus(false)` is every key up.
    With `Window::HOVER`, `Move` with no button held too, while the pointer
    is over the window, and `Leave` when it goes. `dx`, `dy` are how far
    the mouse moved, in its own counts: not sped up, not stopped at the
    screen's edge.
  - `set_pointer(Pointer::Grab)`, for mouse-look: no pointer drawn, and it
    held in the window's middle while the window has the keys, so it never
    leaves; `Move` comes with `dx`, `dy` (with `Window::HOVER` or not).
    The user takes it back with ctrl+alt, until they click in the window
    again. `Pointer::Hidden`: none drawn over the window (it draws its
    own); `Pointer::Arrow` as before.
  - `axiom::Look::get()`: the desktop's scale (`px(points)`), dark or light,
    accent, theme colours, the screen's size.
- **`axiom::Files`**: `get()` (the program's), `read(path)`,
  `read_into(path, buf)`, `size`, `write(path, data)`, `mkdir`, `remove`,
  `rename`, `list(path)`, `volumes()`, `sub(folder, rights)`, `home()`.
  Paths are `vol<n>:/a/b`. A read or a write is 16 MiB at most; a volume
  is written only after the user says `vol <n> rw` in the shell
  (`Error::READONLY` until then), but for what is in `home()`, the boot
  volume's `/Home`, which may always be written.
- **`axiom::Stream`** (`axiom::sound`), with `wants::SOUND`: `open(frames)`
  (a ring of that many, a power of two from 1024 to 65536), `room()`,
  `write(&[Frame])` and `write_with(n, |i| frame)` (as many as fit, ->
  how many), `wait(deadline)` (until no more than the low mark is queued:
  half the ring, or `set_low`), `drain(deadline)`, `queued()`, `played()`,
  `short()` (frames it ran dry for), `set_gain(g)` (`sound::UNITY` as
  written). 48 kHz (`sound::RATE`), a `Frame` is `[left, right]`, `i16`s.
  The mixer sums every stream, then the user's volume; what it takes
  reaches the speakers about 40 ms later. Dropping the stream ends it.
- **`axiom::time`**: `Instant` (the TSC), `micros()`, `nanos()`, `sleep()`,
  `sleep_until()`.
- **`axiom::thread`** (without std): `spawn(f, arg, stack)` for an `extern
  "C" fn(usize)`, `join()`; each thread with its own stack, thread-local
  block and ring. `axiom::sys::futex_wait`, `futex_wake`, `clock_us()`
  (the wall clock), `cpus()`.
- **`axiom::Heap`**: the global allocator. A program maps 128 blocks at
  most at once, so the heap takes few: arenas from 1 MiB, each twice the
  last, to 64 MiB; slots of 40 sizes up to 32 KiB, pages beyond, grown in
  place when it can.
- **`axiom::console`**: `print!`, `println!`, `write(bytes)`.
- **`axiom::args()`**: the words the program was run with, after its name.
- **`axiom::ring`, `axiom::sys`, `axiom::mem`**: the ring, raw system
  calls, blocks of memory, for what the rest does not cover.

## Limits, for now

- No window without a frame: `Window::FULL` is a zoomed window.
- Sound is one format: 48 kHz, 16-bit, stereo; resample to it.
- An .AXE is 16 MiB at most, its zeroes included.
- A program maps 128 blocks at once; each thread's ring takes two.
- A panic aborts (no unwinding), so `catch_unwind` catches nothing.
