//! The parts of Axiom's kernel written in Rust. The kernel is assembly
//! (src/kernel); a piece moves here when Rust says it better, and keeps the
//! calls it had: its entry points are `extern "sysv64"`, and a wrapper in
//! the assembly, where the piece was, keeps the registers and flags its
//! callers expect (src/kernel/rust.asm says how). What stays in assembly is
//! what has to be: the start, interrupt and system call entry, switching
//! threads, and the loops that are fast because of the instructions they
//! use (AES-NI, SHA, the blits).
//!
//! In the kernel, the crate is `no_std` for x86_64-axiom-kernel.json: no
//! SSE (the assembly's interrupts do not save it), no red zone (they push
//! onto the stack in use), linked in the top 2 GiB. For the host it builds
//! with std, for its tests.
//!
//!   json      just enough JSON to talk to a web API (was json.asm)
//!   text      UTF-8 a byte at a time, and the console font's glyphs (was text.asm)
#![cfg_attr(target_os = "none", no_std)]

pub mod json;
pub mod text;

#[cfg(target_os = "none")]
mod kernel {
    use core::cell::UnsafeCell;
    use core::fmt::Write;
    use core::sync::atomic::{AtomicBool, Ordering};

    unsafe extern "sysv64" {
        /// panic(0, message): src/kernel/rust.asm. Never returns.
        fn rust_panic(message: *const u8) -> !;
    }

    /// The report's text, NUL-terminated, cut short to fit.
    struct Report {
        text: [u8; 240],
        len: usize,
    }

    impl Write for Report {
        fn write_str(&mut self, s: &str) -> core::fmt::Result {
            let room = self.text.len() - 1 - self.len;
            let n = s.len().min(room);
            self.text[self.len..self.len + n].copy_from_slice(&s.as_bytes()[..n]);
            self.len += n;
            Ok(())
        }
    }

    /// The one report: written only by whoever set TAKEN first.
    struct Once(UnsafeCell<Report>);

    // SAFETY: see Once
    unsafe impl Sync for Once {}

    static TAKEN: AtomicBool = AtomicBool::new(false);
    static REPORT: Once = Once(UnsafeCell::new(Report {
        text: [0; 240],
        len: 0,
    }));

    /// A panic is the kernel's: its report says what and where, then every
    /// CPU stops.
    #[panic_handler]
    fn panic(info: &core::panic::PanicInfo) -> ! {
        if TAKEN.swap(true, Ordering::AcqRel) {
            // SAFETY: rust_panic takes a NUL-terminated message
            unsafe { rust_panic(c"rust: a panic in a panic".as_ptr().cast()) }
        }
        // SAFETY: only the first to panic gets here, and it never leaves
        let report = unsafe { &mut *REPORT.0.get() };
        let _ = write!(report, "rust: {}", info.message());
        if let Some(at) = info.location() {
            let _ = write!(report, " ({}:{})", at.file(), at.line());
        }
        report.text[report.len] = 0;
        // SAFETY: as above
        unsafe { rust_panic(report.text.as_ptr()) }
    }
}
