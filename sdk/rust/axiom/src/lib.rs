//! Axiom's system interface, for programs written in Rust.
//!
//! A program is built for sdk/rust/x86_64-axiom.json and turned into an
//! .AXE by tools/mkaxe.py (tools/rust.py does both). It says once what it
//! wants to be given.
//!
//! With std (built with -Zbuild-std=std,panic_abort: the target is std's
//! hermit layer, whose system calls this crate supplies, axiom::hermit), a
//! program has a plain `fn main`, and says
//!
//!   axiom::entry!(wants = axiom::wants::DESK);
//!
//! std's threads, clock, locks, thread_local!, files, args and TCP
//! (std::net, with wants::NET) are there. Without std it is #![no_std]
//! and #![no_main], names its main, and says axiom::panic_handler!() (and
//! has a #[global_allocator], to allocate):
//!
//!   axiom::entry!(main, wants = axiom::wants::DESK);
//!
//! Either way, axiom's own modules reach what std doesn't: windows
//! (axiom::window), sound (axiom::sound), the files' volumes, TLS
//! (axiom::net).

#![no_std]
#![feature(thread_local)]

#[cfg(feature = "alloc")]
extern crate alloc;

pub mod chan;
pub mod console;
pub mod files;
pub mod heap;
pub mod mem;
pub mod net;
pub mod ring;
pub mod rt;
pub mod sound;
pub mod sync;
pub mod sys;
pub mod task;
pub mod thread;
pub mod time;
pub mod tls;
pub mod window;
#[cfg(all(target_os = "hermit", feature = "alloc"))]
pub mod hermit;

pub use files::Files;
pub use heap::Heap;
pub use net::Net;
pub use rt::{Args, Termination, args, args_line, wants};
pub use sound::Stream;
pub use sys::{Error, Handle, Result, exit};
pub use time::Instant;
pub use window::{Button, Event, Frame, Key, Look, Mods, Pointer, Window, Zoom};

/// For a program without std: a panic said on the console, and the program
/// ended (101).
#[macro_export]
macro_rules! panic_handler {
    () => {
        #[panic_handler]
        fn panic(info: &core::panic::PanicInfo) -> ! {
            $crate::println!("{}", info);
            $crate::exit(101)
        }
    };
}
