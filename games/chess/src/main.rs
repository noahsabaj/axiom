//! Chess, made with Hearth.
//!
//! The game draws its whole frame on the CPU into one image, shown as a single sprite, so it
//! needs nothing from a renderer but a textured quad: it runs the same on Axiom, which has no
//! GPU, as on the desktop.

mod canvas;
mod pieces;
mod ui;

use hearth::asset::RenderAssetUsages;
use hearth::input::keyboard::{Key, KeyboardInput};
use hearth::input::mouse::{MouseScrollUnit, MouseWheel};
use hearth::prelude::*;
use hearth::image::{Extent3d, TextureDimension, TextureFormat};
use hearth::platform::time::Instant;
use hearth::window::{PrimaryWindow, WindowResizeConstraints};
use canvas::{Canvas, Fonts};
use chess::ai::{Found, LEVELS, Search};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use chess::rules::Color;
use pieces::PieceSet;
use ui::{Chess, Drag, Layout, Mode, Painter, Target};

/// The least time the computer seems to think, in seconds, so its replies don't snap.
const MIN_THINK: f32 = 0.4;

/// How long the computer may think in one frame, in seconds. It thinks on the main thread, a
/// slice a frame, as Axiom may give the game only one thread.
const THINK_SLICE: f32 = 0.012;

/// About how many positions one step of the search looks at before it pauses.
const SLICE_NODES: u64 = 30_000;

static FONT: &[u8] = include_bytes!("../assets/fonts/MonaSans-VariableFont.ttf");

fn main() {
    let mut app = App::new();
    app.add_plugins(DefaultPlugins.set(WindowPlugin {
        primary_window: Some(Window {
            title: "Chess".into(),
            resolution: (1120, 780).into(),
            resize_constraints: WindowResizeConstraints { min_width: 760.0, min_height: 540.0, ..default() },
            ..default()
        }),
        ..default()
    }))
    .insert_resource(ClearColor(to_color(ui::LIGHT_THEME.background)))
    .insert_resource(chess_from_args())
    .init_resource::<Thinking>()
    .insert_non_send(Art { fonts: Fonts::new(FONT), pieces: None, small: None })
    .add_systems(Startup, setup)
    .add_systems(Update, (fit_window, pointer, keys, computer, draw).chain());

    // Lets the `hearth` CLI inspect and drive the app while it runs.
    #[cfg(feature = "remote")]
    app.add_plugins((
        hearth::remote::RemotePlugin::default(),
        hearth::remote::http::RemoteHttpPlugin::default().with_port(remote_port()),
    ));

    app.run();
}

/// The port the app answers the Hearth Remote Protocol on: `HEARTH_REMOTE_PORT`, which `hearth run`
/// sets, else the default.
#[cfg(feature = "remote")]
fn remote_port() -> u16 {
    std::env::var("HEARTH_REMOTE_PORT")
        .ok()
        .and_then(|port| port.parse().ok())
        .unwrap_or(hearth::remote::http::DEFAULT_PORT)
}

/// The table to start with: `--fen <FEN>` sets up a position, `--two` seats two players.
fn chess_from_args() -> Chess {
    let mut chess = Chess::default();
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--fen")
        && let Some(fen) = args.get(i + 1)
    {
        match chess::rules::Game::from_fen(fen) {
            Ok(game) => {
                chess.human = game.position.side;
                chess.game = game;
            }
            Err(e) => error!("bad --fen: {e}"),
        }
    }
    chess.dark = args.iter().any(|a| a == "--dark");
    if args.iter().any(|a| a == "--two") {
        chess.mode = Mode::TwoPlayers;
    }
    chess
}

fn to_color(c: canvas::Rgba) -> hearth::prelude::Color {
    hearth::prelude::Color::srgb_u8(c.r, c.g, c.b)
}

/// The font and the pieces, rendered for the board's current size.
struct Art {
    fonts: Fonts,
    pieces: Option<PieceSet>,
    small: Option<PieceSet>,
}

/// The frame: the canvas the game draws on, and the image and sprite that show it.
#[derive(Resource)]
struct Frame {
    canvas: Canvas,
    image: Handle<Image>,
    sprite: Entity,
}

/// The computer's search, between frames.
#[derive(Resource)]
struct Thinking {
    brain: Option<Brain>,
    since: f32,
    /// Whether the system can start threads. Where it can't, the search runs on the main
    /// thread a slice a frame.
    threads: bool,
}

impl Default for Thinking {
    fn default() -> Self {
        // `--no-threads` tries on the desktop what a system without threads gets.
        let threads = !std::env::args().any(|a| a == "--no-threads") && std::thread::Builder::new().spawn(|| {}).is_ok();
        info!("the computer thinks {}", if threads { "on its own thread" } else { "between frames" });
        Thinking { brain: None, since: 0.0, threads }
    }
}

enum Brain {
    /// Searching on a thread, which puts its answer in the slot.
    Thread { answer: Arc<Mutex<Option<Option<Found>>>>, cancel: Arc<AtomicBool> },
    /// Searching here, a slice a frame.
    Steps(Search),
    /// Found, and waiting to be shown.
    Done(Option<Found>),
}

fn blank_image(w: u32, h: u32) -> Image {
    Image::new_fill(
        Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
        TextureDimension::D2,
        &[0, 0, 0, 255],
        TextureFormat::Rgba8UnormSrgb,
        RenderAssetUsages::MAIN_WORLD | RenderAssetUsages::RENDER_WORLD,
    )
}

fn setup(mut commands: Commands, mut images: ResMut<Assets<Image>>) {
    commands.spawn((Name::new("Camera"), Camera2d));
    let image = images.add(blank_image(1, 1));
    let sprite = commands.spawn((Name::new("Frame"), Sprite::from_image(image.clone()))).id();
    commands.insert_resource(Frame { canvas: Canvas::new(1, 1, 1.0), image, sprite });
}

/// Keeps the canvas the size of the window, in physical pixels.
fn fit_window(
    window: Single<&Window, With<PrimaryWindow>>,
    mut frame: ResMut<Frame>,
    mut images: ResMut<Assets<Image>>,
    mut sprites: Query<&mut Sprite>,
    mut chess: ResMut<Chess>,
) {
    let (w, h) = (window.physical_width() as usize, window.physical_height() as usize);
    let scale = window.scale_factor();
    if w == 0 || h == 0 || (frame.canvas.w == w && frame.canvas.h == h && frame.canvas.scale == scale) {
        return;
    }
    frame.canvas.resize(w, h, scale);
    if let Some(mut image) = images.get_mut(&frame.image) {
        *image = blank_image(w as u32, h as u32);
    }
    if let Ok(mut sprite) = sprites.get_mut(frame.sprite) {
        sprite.custom_size = Some(Vec2::new(window.width(), window.height()));
    }
    chess.dirty = true;
}

fn now(time: &Time) -> f32 {
    time.elapsed_secs()
}

fn pointer(
    window: Single<&Window, With<PrimaryWindow>>,
    buttons: Res<ButtonInput<MouseButton>>,
    mut wheel: MessageReader<MouseWheel>,
    mut chess: ResMut<Chess>,
    mut thinking: ResMut<Thinking>,
    time: Res<Time>,
) {
    let t = now(&time);
    let layout = Layout::new(window.width(), window.height(), &chess);
    let cursor = window.cursor_position().map(|p| (p.x, p.y));
    let hover = cursor.and_then(|(x, y)| layout.hit(x, y, &chess));
    if chess.hover != hover {
        chess.hover = hover;
        chess.dirty = true;
    }

    for event in wheel.read() {
        if hover == Some(Target::MoveList) {
            let rows = match event.unit {
                MouseScrollUnit::Line => event.y,
                MouseScrollUnit::Pixel => event.y / layout.row,
            };
            let history = chess.game.history.len();
            let visible = ((layout.list.h - 8.0) / layout.row).floor().max(1.0) as usize;
            let current = ui::scroll_row(chess.scroll, history.div_ceil(2) + 1, visible) as f32;
            chess.scroll = (current - rows).max(0.0);
            chess.dirty = true;
        }
    }

    let Some((x, y)) = cursor else { return };
    if let Some(drag) = &mut chess.drag {
        if drag.at != (x, y) {
            drag.at = (x, y);
            chess.dirty = true;
        }
    }

    if buttons.just_pressed(MouseButton::Left) {
        press(&mut chess, &mut thinking, hover, (x, y), t);
    }
    if buttons.just_released(MouseButton::Left)
        && let Some(drag) = chess.drag.take()
    {
        chess.dirty = true;
        let to = layout.square_at(x, y, chess.flipped);
        if drag.moved() {
            if let Some(to) = to.filter(|&to| to != drag.from) {
                try_move(&mut chess, drag.from, to, t, false);
            }
        } else if drag.was_selected && to == Some(drag.from) {
            chess.selected = None;
        }
    }
}

fn press(chess: &mut Chess, thinking: &mut Thinking, hover: Option<Target>, at: (f32, f32), t: f32) {
    chess.dirty = true;
    // While choosing a promotion, anything but a choice cancels it.
    if chess.promotion.is_some() {
        match hover {
            Some(Target::Promote(kind)) => {
                let (from, to) = chess.promotion.take().unwrap();
                if let Some(m) = chess.targets_of(from).into_iter().find(|m| m.to == to && m.promotion == Some(kind)) {
                    chess.play(m, t, true);
                }
            }
            _ => chess.promotion = None,
        }
        return;
    }
    match hover {
        Some(Target::Square(sq)) => {
            if let Some(from) = chess.selected
                && chess.players_turn()
                && chess.targets_of(from).iter().any(|m| m.to == sq)
            {
                try_move(chess, from, sq, t, true);
                return;
            }
            let pos = &chess.game.position;
            if chess.players_turn() && pos.at(sq).is_some_and(|p| p.color == pos.side) {
                let was_selected = chess.selected == Some(sq);
                chess.selected = Some(sq);
                chess.drag = Some(Drag { from: sq, at, start: at, was_selected });
            } else {
                chess.selected = None;
            }
        }
        Some(Target::Mode(mode)) if mode != chess.mode => {
            chess.mode = mode;
            stop_thinking(chess, thinking);
            if mode == Mode::Computer {
                // Play the side that's to move, so the computer doesn't move at once.
                chess.human = chess.game.position.side;
                chess.flipped = chess.human == Color::Black;
            }
        }
        Some(Target::Level(level)) => chess.level = level,
        Some(Target::Side(side)) if side != chess.human => {
            chess.human = side;
            chess.flipped = side == Color::Black;
            chess.selected = None;
            stop_thinking(chess, thinking);
        }
        Some(Target::Undo) => {
            stop_thinking(chess, thinking);
            chess.undo();
        }
        Some(Target::Flip) => chess.flipped = !chess.flipped,
        Some(Target::NewGame | Target::Rematch) => {
            stop_thinking(chess, thinking);
            chess.new_game();
        }
        Some(Target::CloseResult) => chess.result_closed = true,
        Some(Target::Appearance) => chess.dark = !chess.dark,
        _ => chess.selected = None,
    }
}

/// Moves from `from` to `to`, asking which piece a pawn becomes when there's a choice.
fn try_move(chess: &mut Chess, from: u8, to: u8, t: f32, slide: bool) {
    let moves: Vec<_> = chess.targets_of(from).into_iter().filter(|m| m.to == to).collect();
    match moves.as_slice() {
        [] => {}
        [m] => chess.play(*m, t, slide),
        _ => {
            chess.promotion = Some((from, to));
            chess.selected = None;
        }
    }
}

fn stop_thinking(chess: &mut Chess, thinking: &mut Thinking) {
    if let Some(Brain::Thread { cancel, .. }) = thinking.brain.take() {
        cancel.store(true, Ordering::Relaxed);
    }
    chess.thinking = false;
}

fn keys(
    mut events: MessageReader<KeyboardInput>,
    held: Res<ButtonInput<KeyCode>>,
    mut chess: ResMut<Chess>,
    mut thinking: ResMut<Thinking>,
) {
    let command = held.any_pressed([KeyCode::ControlLeft, KeyCode::ControlRight, KeyCode::SuperLeft, KeyCode::SuperRight]);
    for e in events.read() {
        if !e.state.is_pressed() {
            continue;
        }
        match (&e.logical_key, e.key_code) {
            (_, KeyCode::Backspace) | (_, KeyCode::ArrowLeft) => {
                stop_thinking(&mut chess, &mut thinking);
                chess.undo();
            }
            (Key::Character(c), _) if c.as_str().eq_ignore_ascii_case("z") && command => {
                stop_thinking(&mut chess, &mut thinking);
                chess.undo();
            }
            (Key::Character(c), _) if c.as_str().eq_ignore_ascii_case("n") => {
                stop_thinking(&mut chess, &mut thinking);
                chess.new_game();
            }
            (Key::Character(c), _) if c.as_str().eq_ignore_ascii_case("d") => {
                chess.dark = !chess.dark;
                chess.dirty = true;
            }
            (Key::Character(c), _) if c.as_str().eq_ignore_ascii_case("f") => {
                chess.flipped = !chess.flipped;
                chess.dirty = true;
            }
            (_, KeyCode::Escape) => {
                chess.selected = None;
                chess.promotion = None;
                chess.dirty = true;
            }
            _ => {}
        }
    }
}

/// Starts the computer thinking on its turn, and plays its move once found.
fn computer(mut chess: ResMut<Chess>, mut thinking: ResMut<Thinking>, time: Res<Time>) {
    let t = now(&time);
    let thinking = &mut *thinking;
    if !chess.computers_turn() {
        stop_thinking(&mut chess, thinking);
        return;
    }
    let Some(brain) = &mut thinking.brain else {
        let pos = chess.game.position;
        let keys = chess.game.keys();
        let seed = (t.to_bits() as u64) << 20 ^ pos.hash ^ chess.game.history.len() as u64;
        let mut search = Search::new(&pos, &keys[..keys.len() - 1], LEVELS[chess.level], seed);
        thinking.brain = Some(if thinking.threads {
            let answer = Arc::new(Mutex::new(None));
            let slot = answer.clone();
            let cancel = search.cancel_flag();
            let spawned = std::thread::Builder::new().name("chess-computer".into()).spawn(move || {
                while !search.step() {}
                *slot.lock().unwrap() = Some(search.result());
            });
            if spawned.is_err() {
                thinking.threads = false;
                return;
            }
            Brain::Thread { answer, cancel }
        } else {
            Brain::Steps(search.sliced(SLICE_NODES))
        });
        thinking.since = t;
        chess.thinking = true;
        chess.dirty = true;
        return;
    };
    let found = match brain {
        Brain::Thread { answer, .. } => answer.lock().unwrap().take(),
        Brain::Steps(search) => {
            let start = Instant::now();
            let mut done = false;
            while !done && start.elapsed().as_secs_f32() < THINK_SLICE {
                done = search.step();
            }
            done.then(|| search.result())
        }
        Brain::Done(found) => Some(*found),
    };
    let Some(found) = found else { return };
    if t - thinking.since < MIN_THINK || chess.slide.is_some() {
        // Keep the answer until the move may show.
        thinking.brain = Some(Brain::Done(found));
        return;
    }
    stop_thinking(&mut chess, thinking);
    if let Some(found) = found {
        info!(
            "{} plays {} (depth {}, {} nodes, score {})",
            LEVELS[chess.level].name,
            chess.game.position.san(found.mv),
            found.depth,
            found.nodes,
            found.score
        );
        chess.play(found.mv, t, true);
    }
}

fn draw(
    window: Single<&Window, With<PrimaryWindow>>,
    mut frame: ResMut<Frame>,
    mut art: NonSendMut<Art>,
    mut images: ResMut<Assets<Image>>,
    mut chess: ResMut<Chess>,
    mut clear: ResMut<ClearColor>,
    time: Res<Time>,
) {
    let t = now(&time);
    if let Some(slide) = chess.slide
        && t - slide.start >= ui::SLIDE
    {
        chess.slide = None;
        chess.dirty = true;
    }
    if !chess.dirty && chess.slide.is_none() {
        return;
    }
    chess.dirty = false;

    let layout = Layout::new(window.width(), window.height(), &chess);
    let scale = frame.canvas.scale;
    let cell = (layout.cell * scale).round() as usize;
    if art.pieces.as_ref().is_none_or(|p| p.size != cell) {
        art.pieces = Some(PieceSet::new(cell));
    }
    let small = (40.0 * scale).round() as usize;
    if art.small.as_ref().is_none_or(|p| p.size != small) {
        art.small = Some(PieceSet::new(small));
    }
    let art = &*art;
    clear.0 = to_color(chess.theme().background);
    let mut painter = Painter {
        canvas: &mut frame.canvas,
        theme: chess.theme(),
        fonts: &art.fonts,
        pieces: art.pieces.as_ref().unwrap(),
        small: art.small.as_ref().unwrap(),
    };
    painter.draw(&layout, &chess, t);

    if let Some(mut image) = images.get_mut(&frame.image)
        && let Some(data) = &mut image.data
        && data.len() == frame.canvas.px.len() * 4
    {
        data.copy_from_slice(frame.canvas.bytes());
    }
}
