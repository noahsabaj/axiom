//! Axiom's system interface, for programs written in Rust.
//!
//! A program is built for sdk/rust/x86_64-axiom.json and turned into an
//! .AXE by tools/mkaxe.py (tools/rust.py does both). It names its entry,
//! and what it wants to be given, once:
//!
//!   axiom::entry!(main, wants = axiom::wants::DESK);
//!
//! Without std it is #![no_std] and #![no_main], and says
//! axiom::panic_handler!() (and has a #[global_allocator], to allocate).
//! With std (built with
//! -Zbuild-std=std,panic_abort: the target is std's zkvm layer, whose
//! system calls this crate supplies) it is #![no_main], and says
//!
//!   #[global_allocator]
//!   static HEAP: axiom::Heap = axiom::Heap::new();
//!
//! std's threads, its clock and its files are not there: they are
//! axiom::time, axiom::files, and one thread for now.

#![no_std]

#[cfg(feature = "alloc")]
extern crate alloc;

pub mod console;
pub mod files;
pub mod heap;
pub mod mem;
pub mod ring;
pub mod rt;
pub mod sync;
pub mod sys;
pub mod time;
pub mod window;
#[cfg(target_os = "zkvm")]
pub mod zkvm;

pub use files::Files;
pub use heap::Heap;
pub use rt::{Args, Termination, args, args_line, wants};
pub use sys::{Error, Handle, Result, exit};
pub use time::Instant;
pub use window::{Button, Event, Frame, Key, Look, Mods, Pointer, Window};

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
