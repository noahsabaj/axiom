# Rust on Axiom

Axiom's programs can be written in Rust, natively: the program is an
ordinary `.AXE`, run from the shell or the dock like any other, talking to
the kernel through its ring. Nothing passes through the Linux layer.

```
sdk/rust/
  x86_64-axiom.json   the target
  axiom/              the crate: the system interface, a heap, std's hooks
  axiom/axiom.ld      the layout of an .AXE (its header made by the linker)
  hello/              rhello: no std; the console, the heap, files, the clock
  demo/               rdemo: std; a window, drawn each frame, and its events
tools/rust.py         builds them into build/esp/EFI/AXIOM/<NAME>.AXE
tools/mkaxe.py        an ELF linked by axiom.ld -> an .AXE
tools/test/rust/      runs both in QEMU
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

**The target says `os: "zkvm"`, `vendor: "axiom"`.** std has no layer for
an operating system it does not know (an unknown `os` does not compile),
but its zkvm layer leaves the system to the platform: a few `extern "C"`
functions (`sys_write`, `sys_alloc_aligned`, `sys_argv`, `sys_rand`, ...),
which the `axiom` crate supplies. So `println!` reaches the console,
`std::env::args()` has the arguments, `HashMap` is seeded by RDRAND, and
`Vec`, `String`, `Box`, `Rc`, formatting and the rest of `alloc` and `core`
are as anywhere. std's threads, clock (`Instant`), files and network are
not there: use `axiom::time`, `axiom::files`, and one thread. To tell Axiom
apart in `cfg`: `target_os = "zkvm"` with `target_vendor = "axiom"`.

## A program

```rust
#![no_main]                                    // and #![no_std] without std

#[global_allocator]
static HEAP: axiom::Heap = axiom::Heap::new();

axiom::entry!(main, wants = axiom::wants::DESK | axiom::wants::FILES);
// axiom::panic_handler!();                    // without std

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
(`entry!(main, wants = ..., stack = 16 << 20)` for another size), `main`
run, and the program ended with what it returned (`()`, an integer, or a
`Result`, whose error is said). `wants` is what the shell gives it, and no
more (`wants::NET`, `STORE`, `DESK`, `FILES`; `+desk` and the like give more
for one run).

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
  - `axiom::Look::get()`: the desktop's scale (`px(points)`), dark or light,
    accent, theme colours, the screen's size.
- **`axiom::Files`**: `get()` (the program's), `read(path)`,
  `read_into(path, buf)`, `size`, `write(path, data)`, `mkdir`, `remove`,
  `rename`, `list(path)`, `volumes()`, `sub(folder, rights)`. Paths are
  `vol<n>:/a/b`. A read or a write is 16 MiB at most; a volume is written
  only after the user says `vol <n> rw` in the shell (`Error::READONLY`
  until then).
- **`axiom::time`**: `Instant` (the TSC), `micros()`, `nanos()`, `sleep()`,
  `sleep_until()`.
- **`axiom::Heap`**: the global allocator. A program maps 128 blocks at
  most at once, so the heap takes few: arenas from 1 MiB, each twice the
  last, to 64 MiB; slots of 40 sizes up to 32 KiB, pages beyond, grown in
  place when it can.
- **`axiom::console`**: `print!`, `println!`, `write(bytes)`.
- **`axiom::args()`**: the words the program was run with, after its name.
- **`axiom::ring`, `axiom::sys`, `axiom::mem`**: the ring, raw system
  calls, blocks of memory, for what the rest does not cover.

## Limits, for now

- One thread: the ring is held while a call waits.
- No window without a frame: `Window::FULL` is a zoomed window. The
  pointer is not held or hidden for a game to look around with.
- An .AXE is 16 MiB at most, its zeroes included.
- `std::process::exit` aborts: return from `main`, or call `axiom::exit`.
