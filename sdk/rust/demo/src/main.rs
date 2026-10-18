//! rdemo: Rust on Axiom with std. Opens a window that can be resized and
//! draws it each frame (about 60 a second): a plain ground, a bar sweeping
//! across the top, and a square where the mouse last pressed or dragged.
//! Says each key, press and resize on the console ("rdemo: ..."); q, Esc or
//! the close button end it, with a count of what happened.
//!
//!   rdemo [title]

#![no_main]

use std::collections::HashMap;
use std::time::Duration;

use axiom::{Event, Instant, Key, Window};

#[global_allocator]
static HEAP: axiom::Heap = axiom::Heap::new();

axiom::entry!(main, wants = axiom::wants::DESK);

const GROUND: u32 = 0x20_3040;
const BAR: u32 = 0x5A_C8FA;
const MARK: u32 = 0xE0_A030;
const SQUARE: i32 = 40;

fn main() -> Result<(), axiom::Error> {
    let title: Vec<String> = std::env::args().skip(1).collect();
    let title = if title.is_empty() { "Rust on Axiom".to_string() } else { title.join(" ") };
    println!("rdemo: std says hello, {} args", std::env::args().count());

    let mut w = Window::open(640, 400, Window::RESIZE)?;
    w.set_title(&title);
    let mut seen: HashMap<&'static str, u32> = HashMap::new();
    let mut mark = (100, 100);
    let mut frames = 0u64;
    let start = Instant::now();
    loop {
        let next = Instant::now() + Duration::from_millis(16);
        while let Some(e) = w.wait(Some(next)) {
            let name = match e {
                Event::Key { key, mods, .. } => {
                    println!("rdemo: key {:?}{}", key, if mods.ctrl() { " ctrl" } else { "" });
                    if matches!(key, Key::Char('q') | Key::Escape) {
                        return bye(&seen, frames, start);
                    }
                    "key"
                }
                Event::Press { button, x, y } => {
                    println!("rdemo: press {:?} at {},{}", button, x, y);
                    mark = (x, y);
                    "press"
                }
                Event::Move { x, y } => {
                    mark = (x, y);
                    "move"
                }
                Event::Resized { width, height } => {
                    println!("rdemo: resized {}x{}", width, height);
                    "resized"
                }
                Event::Close | Event::Gone => return bye(&seen, frames, start),
                Event::Release { .. } => "release",
                Event::Wheel { .. } => "wheel",
                Event::Look => "look",
                Event::Focus(_) => "focus",
            };
            *seen.entry(name).or_default() += 1;
        }
        draw(&mut w, mark, frames);
        w.show();
        frames += 1;
        if frames == 1 {
            let (width, height) = w.size();
            println!("rdemo: first frame {}x{}, stride {}", width, height, w.stride());
        }
    }
}

fn draw(w: &mut Window, mark: (i32, i32), frame: u64) {
    let mut f = w.frame();
    f.fill(GROUND);
    let span = f.width as i32 + 120;
    let x = (frame as i32 * 6) % span - 120;
    f.fill_rect(x, 0, 120, 8, BAR);
    f.fill_rect(mark.0 - SQUARE / 2, mark.1 - SQUARE / 2, SQUARE, SQUARE, MARK);
}

fn bye(seen: &HashMap<&str, u32>, frames: u64, start: Instant) -> Result<(), axiom::Error> {
    let mut kinds: Vec<_> = seen.iter().collect();
    kinds.sort();
    let secs = start.elapsed().as_secs_f64();
    println!("rdemo: {} frames in {:.1} s; {:?}", frames, secs, kinds);
    Ok(())
}
