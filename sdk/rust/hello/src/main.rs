//! rhello: Rust on Axiom without std. Says hello, its arguments, works the
//! heap (small and large, freed and reused, aligned), lists the volumes,
//! reads its own .AXE back and checks its header, and sleeps a while by the
//! clock. Each line starts "rhello:", for the test to find.
//!
//!   rhello [words ...]

#![no_std]
#![no_main]

extern crate alloc;

use alloc::vec::Vec;
use core::time::Duration;

use axiom::files::VOL_BOOT;
use axiom::{Files, Instant, println};

#[global_allocator]
static HEAP: axiom::Heap = axiom::Heap::new();

axiom::entry!(main, wants = axiom::wants::FILES);
axiom::panic_handler!();

fn main() -> axiom::Result<()> {
    println!("rhello: hello from Rust");
    let args: Vec<&str> = axiom::args().collect();
    println!("rhello: {} args {:?}", args.len(), args);

    // the heap: slots of every size, freed, taken again; blocks of their own
    let mut keep: Vec<Vec<u8>> = Vec::new();
    let mut total = 0usize;
    for i in 0..3000usize {
        let n = (i * 37) % 40000 + 1;
        let v = alloc::vec![(i % 251) as u8; n];
        total += v.len();
        if i % 3 == 0 {
            keep.push(v);
        }
    }
    let ok = keep.iter().enumerate().all(|(k, v)| {
        let i = k * 3;
        v.len() == (i * 37) % 40000 + 1 && v.iter().all(|&b| b == (i % 251) as u8)
    });
    let big = alloc::vec![7u32; 3 << 20]; // 12 MiB, an arena of its own
    let mut grown = Vec::new(); // grown in place, mostly
    for i in 0..2_000_000u64 {
        grown.push(i);
    }
    let grown_ok = grown.iter().sum::<u64>() == 1_999_999 * 2_000_000 / 2;
    let aligned = alloc::alloc::Layout::from_size_align(100, 4096).unwrap();
    let p = unsafe { alloc::alloc::alloc(aligned) };
    let page = p as usize % 4096 == 0;
    unsafe { alloc::alloc::dealloc(p, aligned) };
    println!(
        "rhello: heap {} bytes, {} kept, {}, big {}, grown {}, aligned {}",
        total,
        keep.len(),
        if ok { "intact" } else { "CORRUPT" },
        big.iter().map(|&x| x as u64).sum::<u64>(),
        grown_ok,
        page
    );
    drop(keep);
    drop(big);

    // files: the volumes, and this program's own file
    let files = Files::get()?;
    let vols = files.volumes()?;
    for v in &vols {
        println!("rhello: vol{} '{}' {} MiB flags {}", v.index, v.label, v.bytes >> 20, v.flags);
    }
    if let Some(boot) = vols.iter().find(|v| v.flags & VOL_BOOT != 0) {
        let path = alloc::format!("vol{}:/EFI/AXIOM/RHELLO.AXE", boot.index);
        let me = files.read(&path)?;
        println!("rhello: read {} bytes of {}, magic {}", me.len(), path,
                 core::str::from_utf8(&me[..8]).unwrap_or("?"));
        let listed = files.list(&alloc::format!("vol{}:/EFI/AXIOM", boot.index))?;
        let found = listed.iter().find(|e| e.name.eq_ignore_ascii_case("RHELLO.AXE"));
        println!("rhello: listed {} things, RHELLO.AXE {}", listed.len(),
                 found.map_or(0, |e| e.size));
    }

    // the clock
    let t = Instant::now();
    axiom::time::sleep(Duration::from_millis(50));
    let ms = t.elapsed().as_millis();
    println!("rhello: slept {} ms", ms);
    println!("rhello: done");
    Ok(())
}
