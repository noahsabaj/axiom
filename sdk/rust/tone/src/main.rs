//! rtone: Rust on Axiom playing sound, without std. A sine through a stream
//! (axiom::sound): written while there is room, waited on for more, then
//! drained. Its last line starts "rtone:", for the test to find.
//!
//!   rtone [hz [ms]]      660 Hz for half a second unless said

#![no_std]
#![no_main]

use core::time::Duration;

use axiom::sound::{Frame, RATE};
use axiom::{Instant, Stream, println};

#[global_allocator]
static HEAP: axiom::Heap = axiom::Heap::new();

axiom::entry!(main, wants = axiom::wants::SOUND);
axiom::panic_handler!();

/// A sine by the magic circle, in integers: x -= e y, y += e x.
struct Sine {
    x: i64,
    y: i64,
    e: i64,
}

impl Sine {
    fn new(hz: u32, peak: i16) -> Sine {
        // e = 2 pi f / RATE, << 16
        Sine { x: (peak as i64) << 12, y: 0, e: (hz as i64 * 562_210) >> 16 }
    }

    fn next(&mut self) -> i16 {
        self.x -= (self.e * self.y) >> 16;
        self.y += (self.e * self.x) >> 16;
        (self.y >> 12) as i16
    }
}

fn main() -> axiom::Result<()> {
    let mut args = axiom::args();
    let hz = args.next().and_then(|a| a.parse().ok()).unwrap_or(660u32);
    let ms = args.next().and_then(|a| a.parse().ok()).unwrap_or(500u32);
    let mut s = Stream::open(4096)?;
    let mut sine = Sine::new(hz, 12000);
    let total = (ms as usize) * (RATE as usize) / 1000;
    let mut left = total;
    let patience = || Some(Instant::now() + Duration::from_secs(2));
    while left > 0 {
        let n = s.write_with(left, |_| {
            let v = sine.next();
            [v, v] as Frame
        });
        left -= n;
        if left > 0 {
            s.wait(patience())?;
        }
    }
    let short = s.short();
    s.drain(patience())?;
    println!("rtone: {} Hz for {} ms, {} frames played, {} short", hz, ms, total, short);
    Ok(())
}
