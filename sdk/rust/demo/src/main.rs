//! rdemo: Rust on Axiom with std. Opens a window that can be resized and
//! draws it each frame (about 60 a second): a plain ground, a bar sweeping
//! across the top, and a square where the mouse last pressed or dragged.
//! Says each key (as text, and down and up), press, resize, the pointer
//! over it and leaving, the keys gained and lost, full screen or not, on
//! the console ("rdemo: ..."); g holds the pointer (a game's mouse-look) or
//! lets it go; f goes full screen or back; o opens a second, small window
//! (which takes the keys, and cannot go full screen); q, Esc or the close
//! button end it, with a count of what happened.
//!
//!   rdemo [--full | --screen] [title]

use std::collections::HashMap;
use std::time::Duration;

use axiom::{Event, Instant, Key, Pointer, Window, Zoom};

axiom::entry!(wants = axiom::wants::DESK);

const GROUND: u32 = 0x20_3040;
const BAR: u32 = 0x5A_C8FA;
const MARK: u32 = 0xE0_A030;
const SQUARE: i32 = 40;

fn main() -> Result<(), axiom::Error> {
    let mut title: Vec<String> = std::env::args().skip(1).collect();
    let size = match title.first().map(|a| a.as_str()) {
        Some("--full") => Window::FULL,
        Some("--screen") => Window::SCREEN,
        _ => Window::RESIZE,
    };
    if size != Window::RESIZE {
        title.remove(0);
    }
    let title = if title.is_empty() { "Rust on Axiom".to_string() } else { title.join(" ") };
    println!("rdemo: std says hello, {} args", std::env::args().count());

    let mut w = Window::open(640, 400, size | Window::KEYS | Window::HOVER)?;
    w.set_title(&title);
    let mut seen: HashMap<&'static str, u32> = HashMap::new();
    let mut mark = (100, 100);
    let mut held = 0u32;
    let mut grab = false;
    let mut zoom = Zoom::Normal;
    let mut two: Option<Window> = None;
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
                    if key == Key::Char('g') {
                        grab = !grab;
                        let p = if grab { Pointer::Grab } else { Pointer::Arrow };
                        w.set_pointer(p);
                        println!("rdemo: pointer {:?}", p);
                    }
                    if key == Key::Char('f') {
                        let z = if zoom == Zoom::Screen { Zoom::Normal } else { Zoom::Screen };
                        println!("rdemo: asked {:?}, {:?}", z, w.set_zoom(z));
                    }
                    if key == Key::Char('o') && two.is_none() {
                        let t = Window::open(320, 200, 0)?;
                        t.set_title("rdemo two");
                        // not one that can be resized: never full screen
                        println!("rdemo: a second window, full screen {:?}", t.set_zoom(Zoom::Screen));
                        two = Some(t);
                    }
                    "key"
                }
                Event::KeyDown { usage, mods } => {
                    println!("rdemo: down {:#04x}{}", usage, if mods.ctrl() { " ctrl" } else { "" });
                    "down"
                }
                Event::KeyUp { usage, .. } => {
                    println!("rdemo: up {:#04x}", usage);
                    "up"
                }
                Event::Press { button, x, y } => {
                    println!("rdemo: press {:?} at {},{}", button, x, y);
                    held += 1;
                    mark = (x, y);
                    "press"
                }
                Event::Move { x, y, .. } if held > 0 => {
                    mark = (x, y);
                    "move"
                }
                Event::Move { x, y, dx, dy } => {
                    if seen.get("hover").copied().unwrap_or(0) < 20 {
                        println!("rdemo: hover at {},{} by {},{}", x, y, dx, dy);
                    }
                    "hover"
                }
                Event::Leave => {
                    println!("rdemo: left");
                    "leave"
                }
                Event::Resized { width, height } => {
                    println!("rdemo: resized {}x{}", width, height);
                    "resized"
                }
                Event::Close | Event::Gone => return bye(&seen, frames, start),
                Event::Release { .. } => {
                    held = held.saturating_sub(1);
                    "release"
                }
                Event::Wheel { .. } => "wheel",
                Event::Look => "look",
                Event::Focus(b) => {
                    println!("rdemo: focus {}", b);
                    "focus"
                }
                Event::Zoom(z) => {
                    println!("rdemo: zoom {:?}", z);
                    zoom = z;
                    "zoom"
                }
            };
            *seen.entry(name).or_default() += 1;
        }
        if let Some(t) = two.as_mut() {
            let mut gone = false;
            while let Some(e) = t.poll() {
                match e {
                    Event::Key { key: Key::Char('q') | Key::Escape, .. } => {
                        return bye(&seen, frames, start);
                    }
                    Event::Close | Event::Gone => gone = true,
                    _ => {}
                }
            }
            if gone {
                two = None;
            } else {
                t.frame().fill(MARK);
                t.show();
            }
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
