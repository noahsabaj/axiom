//! What the player sees and touches: the state of the table, its layout, and drawing it.

use crate::canvas::{Canvas, Fonts, Rect, Rgba, Weight, rgb, rgba};
use crate::pieces::PieceSet;
use chess::ai::LEVELS;
use chess::rules::{Color, Game, Kind, Move, MoveKind, Outcome, Piece, Square, file_of, rank_of, square};

pub const BACKGROUND: Rgba = rgb(242, 242, 247);
const CARD: Rgba = rgb(255, 255, 255);
const TEXT: Rgba = rgb(29, 29, 31);
const SECONDARY: Rgba = rgb(110, 110, 115);
const TERTIARY: Rgba = rgb(168, 168, 173);
const ACCENT: Rgba = rgb(0, 113, 227);
const FILL: Rgba = rgb(232, 232, 237);
const LIGHT: Rgba = rgb(236, 239, 242);
const DARK: Rgba = rgb(141, 162, 182);
/// The tint of the last move's squares and, stronger, the selected one.
const TINT: Rgba = rgb(64, 150, 255);
const HINT: Rgba = rgba(22, 32, 52, 46);
const CHECK: Rgba = rgba(255, 59, 48, 210);
const SHADOW: Rgba = rgba(0, 0, 0, 30);

/// How long a move takes to slide, in seconds.
pub const SLIDE: f32 = 0.18;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Computer,
    TwoPlayers,
}

/// A piece being dragged.
#[derive(Clone, Copy, Debug)]
pub struct Drag {
    pub from: Square,
    /// Where the pointer is, in logical pixels.
    pub at: (f32, f32),
    /// Where the press began.
    pub start: (f32, f32),
    /// Whether the piece was already selected when the press began, so a click unselects it.
    pub was_selected: bool,
}

impl Drag {
    pub fn moved(&self) -> bool {
        (self.at.0 - self.start.0).hypot(self.at.1 - self.start.1) > 4.0
    }
}

/// A move sliding into place.
#[derive(Clone, Copy, Debug)]
pub struct Slide {
    pub mv: Move,
    pub piece: Piece,
    pub start: f32,
}

/// Everything about the table that isn't the engine's.
#[derive(bevy::prelude::Resource)]
pub struct Chess {
    pub game: Game,
    pub mode: Mode,
    pub level: usize,
    /// The side the player plays against the computer.
    pub human: Color,
    /// Whether Black sits at the bottom.
    pub flipped: bool,
    pub selected: Option<Square>,
    pub drag: Option<Drag>,
    /// A pawn move waiting for the player to pick the piece it becomes.
    pub promotion: Option<(Square, Square)>,
    pub slide: Option<Slide>,
    pub thinking: bool,
    pub hover: Option<Target>,
    /// How far the move list is scrolled, in rows from the top.
    pub scroll: f32,
    /// Whether the player closed the card that says how the game ended.
    pub result_closed: bool,
    pub dirty: bool,
}

impl Default for Chess {
    fn default() -> Self {
        Chess {
            game: Game::default(),
            mode: Mode::Computer,
            level: 1,
            human: Color::White,
            flipped: false,
            selected: None,
            drag: None,
            promotion: None,
            slide: None,
            thinking: false,
            hover: None,
            scroll: 0.0,
            result_closed: false,
            dirty: true,
        }
    }
}

impl Chess {
    /// Whether the player at the screen may move now.
    pub fn players_turn(&self) -> bool {
        !self.game.is_over()
            && self.promotion.is_none()
            && match self.mode {
                Mode::TwoPlayers => true,
                Mode::Computer => self.game.position.side == self.human,
            }
    }

    pub fn computers_turn(&self) -> bool {
        self.mode == Mode::Computer && !self.game.is_over() && self.game.position.side != self.human
    }

    pub fn targets_of(&self, from: Square) -> Vec<Move> {
        self.game.legal_moves().iter().copied().filter(|m| m.from == from).collect()
    }

    /// Plays a move, sliding it into place unless `slide` is false.
    pub fn play(&mut self, m: Move, now: f32, slide: bool) {
        let piece = self.game.position.at(m.from);
        if self.game.play(m) {
            self.slide = match (slide, piece) {
                (true, Some(piece)) => Some(Slide { mv: m, piece, start: now }),
                _ => None,
            };
            self.selected = None;
            self.drag = None;
            self.promotion = None;
            self.scroll = f32::MAX;
            self.dirty = true;
        }
    }

    pub fn new_game(&mut self) {
        self.game = Game::default();
        self.reset_view();
        self.flipped = self.mode == Mode::Computer && self.human == Color::Black;
    }

    /// Takes back moves: the computer's reply too, so it's the player's turn again.
    pub fn undo(&mut self) {
        let mut undone = self.game.undo();
        if undone && self.mode == Mode::Computer && self.game.position.side != self.human {
            undone = self.game.undo();
        }
        if undone || self.thinking {
            self.reset_view();
        }
    }

    fn reset_view(&mut self) {
        self.selected = None;
        self.drag = None;
        self.promotion = None;
        self.slide = None;
        self.thinking = false;
        self.result_closed = false;
        self.scroll = f32::MAX;
        self.dirty = true;
    }

    fn status(&self) -> String {
        if let Some(outcome) = self.game.outcome() {
            return match outcome {
                Outcome::Checkmate { winner } => format!("Checkmate. {} wins.", winner.name()),
                o => format!("{}.", o.title()),
            };
        }
        let side = self.game.position.side;
        let check = if self.game.position.in_check() { ", in check" } else { "" };
        match self.mode {
            Mode::Computer if side != self.human => {
                if check.is_empty() { "Thinking…".into() } else { "In check. Thinking…".into() }
            }
            Mode::Computer => format!("Your move{check}"),
            Mode::TwoPlayers => format!("{} to move{check}", side.name()),
        }
    }
}

/// Something on screen the pointer can act on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Target {
    Square(Square),
    Mode(Mode),
    Level(usize),
    Side(Color),
    Undo,
    Flip,
    NewGame,
    Promote(Kind),
    CloseResult,
    /// New Game on the card that says how the game ended.
    Rematch,
    MoveList,
}

pub struct Layout {
    pub board: Rect,
    pub cell: f32,
    pub panel: Rect,
    pub list: Rect,
    pub row: f32,
    targets: Vec<(Target, Rect)>,
}

const MARGIN: f32 = 28.0;
const PANEL: f32 = 320.0;
const PAD: f32 = 20.0;
const ROW: f32 = 26.0;

impl Layout {
    pub fn new(w: f32, h: f32, chess: &Chess) -> Layout {
        let size = ((h - 2.0 * MARGIN).min(w - PANEL - 3.0 * MARGIN)).max(200.0);
        let cell = (size / 8.0).floor();
        let size = cell * 8.0;
        let total = size + MARGIN + PANEL;
        let x = ((w - total) / 2.0).max(MARGIN).floor();
        let board = Rect::new(x, ((h - size) / 2.0).floor(), size, size);
        let panel = Rect::new(board.right() + MARGIN, board.y, PANEL, size);
        let mut l = Layout { board, cell, panel, list: Rect::default(), row: ROW, targets: Vec::new() };

        let inner = panel.inset(PAD);
        let mut y = inner.y + 76.0;
        let seg = |l: &mut Layout, y: f32, items: Vec<Target>| {
            let w = inner.w / items.len() as f32;
            for (i, t) in items.into_iter().enumerate() {
                l.targets.push((t, Rect::new(inner.x + w * i as f32, y, w, 30.0)));
            }
        };
        seg(&mut l, y, vec![Target::Mode(Mode::Computer), Target::Mode(Mode::TwoPlayers)]);
        y += 40.0;
        if chess.mode == Mode::Computer {
            seg(&mut l, y, (0..LEVELS.len()).map(Target::Level).collect());
            y += 40.0;
            seg(&mut l, y, vec![Target::Side(Color::White), Target::Side(Color::Black)]);
            y += 40.0;
        }
        // Two rows of taken pieces, then the move list down to the buttons.
        y += 8.0 + 2.0 * 28.0 + 10.0;
        let buttons = inner.bottom() - 36.0;
        l.list = Rect::new(inner.x, y, inner.w, (buttons - 14.0 - y).max(ROW));
        l.targets.push((Target::MoveList, l.list));
        let bw = (inner.w - 16.0) / 3.0;
        for (i, t) in [Target::Undo, Target::Flip, Target::NewGame].into_iter().enumerate() {
            l.targets.push((t, Rect::new(inner.x + (bw + 8.0) * i as f32, buttons, bw, 36.0)));
        }

        if let Some((_, to)) = chess.promotion {
            for (i, kind) in Kind::PROMOTIONS.into_iter().enumerate() {
                l.targets.push((Target::Promote(kind), l.promotion_cell(to, i, chess.flipped)));
            }
        }
        if chess.game.is_over() && !chess.result_closed && chess.slide.is_none() {
            let card = l.result_card();
            let half = (card.w - 3.0 * 16.0) / 2.0;
            l.targets.push((Target::CloseResult, Rect::new(card.x + 16.0, card.bottom() - 52.0, half, 36.0)));
            l.targets.push((Target::Rematch, Rect::new(card.x + 32.0 + half, card.bottom() - 52.0, half, 36.0)));
        }
        l
    }

    /// The screen rectangle of a square.
    pub fn cell_rect(&self, sq: Square, flipped: bool) -> Rect {
        let (f, r) = (file_of(sq) as f32, rank_of(sq) as f32);
        let (col, row) = if flipped { (7.0 - f, r) } else { (f, 7.0 - r) };
        Rect::new(self.board.x + col * self.cell, self.board.y + row * self.cell, self.cell, self.cell)
    }

    pub fn square_at(&self, x: f32, y: f32, flipped: bool) -> Option<Square> {
        if !self.board.contains(x, y) {
            return None;
        }
        let col = (((x - self.board.x) / self.cell) as u8).min(7);
        let row = (((y - self.board.y) / self.cell) as u8).min(7);
        Some(if flipped { square(7 - col, row) } else { square(col, 7 - row) })
    }

    /// The `i`th choice of the promotion picker, stacked from the promotion square inwards.
    fn promotion_cell(&self, to: Square, i: usize, flipped: bool) -> Rect {
        let r = self.cell_rect(to, flipped);
        let down = r.y < self.board.y + self.cell / 2.0;
        let dy = if down { i as f32 * self.cell } else { -(i as f32) * self.cell };
        Rect::new(r.x, r.y + dy, r.w, r.h)
    }

    fn result_card(&self) -> Rect {
        let (w, h) = (288.0, 168.0);
        let (cx, cy) = self.board.center();
        Rect::new((cx - w / 2.0).round(), (cy - h / 2.0).round(), w, h)
    }

    /// What's under the pointer: the last-added target wins, as it's drawn on top.
    pub fn hit(&self, x: f32, y: f32, chess: &Chess) -> Option<Target> {
        if let Some((t, _)) = self.targets.iter().rev().find(|(_, r)| r.contains(x, y)) {
            return Some(*t);
        }
        self.square_at(x, y, chess.flipped).map(Target::Square)
    }

    fn rect_of(&self, t: Target) -> Option<Rect> {
        self.targets.iter().rev().find(|(x, _)| *x == t).map(|(_, r)| *r)
    }
}

/// Eases a slide in and out.
fn ease(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

pub struct Painter<'a> {
    pub canvas: &'a mut Canvas,
    pub fonts: &'a Fonts,
    pub pieces: &'a PieceSet,
    pub small: &'a PieceSet,
}

impl Painter<'_> {
    pub fn draw(&mut self, l: &Layout, chess: &Chess, now: f32) {
        self.canvas.clear(BACKGROUND);
        self.board(l, chess, now);
        self.panel(l, chess);
        if chess.promotion.is_some() {
            self.promotion(l, chess);
        }
        if chess.game.is_over() && !chess.result_closed && chess.slide.is_none() {
            self.result(l, chess);
        }
    }

    fn piece(&mut self, piece: Piece, r: Rect, alpha: f32) {
        let bm = self.pieces.get(piece.color, piece.kind);
        let size = bm.w as f32 / self.canvas.scale;
        self.canvas.blit(bm, r.x + (r.w - size) / 2.0, r.y + (r.h - size) / 2.0, alpha);
    }

    fn board(&mut self, l: &Layout, chess: &Chess, now: f32) {
        let c = &mut *self.canvas;
        let flipped = chess.flipped;
        c.shadow(l.board.inset(2.0), 10.0, 18.0, SHADOW);
        let pos = &chess.game.position;
        let last = chess.game.last_move();
        for sq in 0..64u8 {
            let light = (file_of(sq) + rank_of(sq)) % 2 == 1;
            let base = if light { LIGHT } else { DARK };
            let tint = if chess.selected == Some(sq) {
                0.5
            } else if last.is_some_and(|m| m.from == sq || m.to == sq) {
                0.3
            } else {
                0.0
            };
            c.fill_rect(l.cell_rect(sq, flipped), base.mix(TINT, tint));
        }
        if pos.in_check() {
            c.glow(l.cell_rect(pos.king(pos.side), flipped), l.cell * 0.7, CHECK);
        }
        c.round_corners(l.board, 10.0, BACKGROUND);

        // Coordinates, in the corner squares of the edge files and ranks.
        let size = (l.cell * 0.15).clamp(9.0, 13.0);
        for i in 0..8u8 {
            let (file_sq, rank_sq) = if flipped { (square(7 - i, 7), square(7, i)) } else { (square(i, 0), square(0, i)) };
            let ink = |sq: Square| if (file_of(sq) + rank_of(sq)) % 2 == 1 { DARK } else { LIGHT };
            let r = l.cell_rect(file_sq, flipped);
            let label = ((b'a' + file_of(file_sq)) as char).to_string();
            let w = self.fonts.width(Weight::Semibold, size, &label);
            c.text(self.fonts, Weight::Semibold, size, r.right() - w - 4.0, r.bottom() - 4.0, ink(file_sq), &label);
            let r = l.cell_rect(rank_sq, flipped);
            let label = (rank_of(rank_sq) + 1).to_string();
            c.text(self.fonts, Weight::Semibold, size, r.x + 4.0, r.y + size + 3.0, ink(rank_sq), &label);
        }

        // The pieces, leaving out the one being dragged and the ones sliding.
        let slide = chess.slide.filter(|s| now - s.start < SLIDE);
        let dragging = chess.drag.filter(|d| d.moved()).map(|d| d.from);
        let rook_slide = slide.and_then(|s| castle_rook(s.mv));
        for sq in 0..64u8 {
            let Some(p) = pos.at(sq) else { continue };
            if slide.is_some_and(|s| s.mv.to == sq) || rook_slide.is_some_and(|(_, to)| to == sq) {
                continue;
            }
            let alpha = if dragging == Some(sq) { 0.35 } else { 1.0 };
            self.piece(p, l.cell_rect(sq, flipped), alpha);
        }

        // Where the selected piece can go: dots on empty squares, rings round captures.
        let from = chess.selected.or(chess.drag.map(|d| d.from));
        if let Some(from) = from.filter(|_| chess.players_turn()) {
            for m in chess.targets_of(from) {
                let r = l.cell_rect(m.to, flipped);
                let (x, y) = r.center();
                if m.is_capture() {
                    self.canvas.ring(x, y, l.cell * 0.47, l.cell * 0.075, HINT);
                } else {
                    self.canvas.circle(x, y, l.cell * 0.16, HINT);
                }
            }
        }

        if let Some(s) = slide {
            let t = ease((now - s.start) / SLIDE);
            let lerp = |a: Rect, b: Rect| Rect::new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.w, a.h);
            if let Some((rf, rt)) = rook_slide {
                let rook = Piece::new(s.piece.color, Kind::Rook);
                self.piece(rook, lerp(l.cell_rect(rf, flipped), l.cell_rect(rt, flipped)), 1.0);
            }
            let shown = Piece::new(s.piece.color, s.mv.promotion.unwrap_or(s.piece.kind));
            let piece = if t < 0.6 { s.piece } else { shown };
            self.piece(piece, lerp(l.cell_rect(s.mv.from, flipped), l.cell_rect(s.mv.to, flipped)), 1.0);
        }

        if let Some(d) = chess.drag.filter(|d| d.moved())
            && let Some(p) = pos.at(d.from)
        {
            let size = l.cell * 1.08;
            let r = Rect::new(d.at.0 - size / 2.0, d.at.1 - size / 2.0, size, size);
            self.piece(p, r, 1.0);
        }
    }

    fn segmented(&mut self, l: &Layout, items: &[(Target, &str)], selected: Target, hover: Option<Target>) {
        let rects: Vec<Rect> = items.iter().filter_map(|(t, _)| l.rect_of(*t)).collect();
        let (Some(first), Some(last)) = (rects.first(), rects.last()) else { return };
        let track = Rect::new(first.x, first.y, last.right() - first.x, first.h);
        let c = &mut *self.canvas;
        c.round_rect(track, 9.0, FILL);
        for ((t, label), r) in items.iter().zip(&rects) {
            let on = *t == selected;
            if on {
                let knob = r.inset(2.0);
                c.shadow(knob.inset(1.0), 7.0, 3.0, rgba(0, 0, 0, 34));
                c.round_rect(knob, 7.0, CARD);
            } else if hover == Some(*t) {
                c.round_rect(r.inset(2.0), 7.0, rgba(255, 255, 255, 110));
            }
            let (cx, cy) = r.center();
            let weight = if on { Weight::Semibold } else { Weight::Medium };
            c.text_centered(self.fonts, weight, 13.0, cx, cy + 4.5, if on { TEXT } else { SECONDARY }, label);
        }
    }

    fn panel(&mut self, l: &Layout, chess: &Chess) {
        let fonts = self.fonts;
        let p = l.panel;
        self.canvas.shadow(p.inset(2.0), 16.0, 18.0, SHADOW);
        self.canvas.round_rect(p, 16.0, CARD);
        let inner = p.inset(PAD);
        self.canvas.text(fonts, Weight::Semibold, 26.0, inner.x, inner.y + 26.0, TEXT, "Chess");
        let status_color = if chess.game.is_over() { TEXT } else { SECONDARY };
        self.canvas.text(fonts, Weight::Regular, 14.0, inner.x, inner.y + 50.0, status_color, &chess.status());

        self.segmented(
            l,
            &[(Target::Mode(Mode::Computer), "Computer"), (Target::Mode(Mode::TwoPlayers), "Two Players")],
            Target::Mode(chess.mode),
            chess.hover,
        );
        let mut y = l.rect_of(Target::Mode(Mode::Computer)).map_or(0.0, |r| r.bottom());
        if chess.mode == Mode::Computer {
            let levels: Vec<(Target, &str)> = LEVELS.iter().enumerate().map(|(i, lv)| (Target::Level(i), lv.name)).collect();
            self.segmented(l, &levels, Target::Level(chess.level), chess.hover);
            self.segmented(
                l,
                &[(Target::Side(Color::White), "Play White"), (Target::Side(Color::Black), "Play Black")],
                Target::Side(chess.human),
                chess.hover,
            );
            y = l.rect_of(Target::Side(Color::White)).map_or(y, |r| r.bottom());
        }

        // Taken pieces: the top row for the side at the top of the board.
        let (top, bottom) = if chess.flipped { (Color::White, Color::Black) } else { (Color::Black, Color::White) };
        let worth = |c: Color| chess.game.captured_by(c).iter().map(|p| piece_value(p.kind)).sum::<i32>();
        let diff = worth(Color::White) - worth(Color::Black);
        if chess.game.history.iter().all(|p| p.captured.is_none()) {
            self.canvas.text(fonts, Weight::Regular, 13.0, inner.x, y + 34.0, TERTIARY, "No captures yet");
        }
        for (i, side) in [top, bottom].into_iter().enumerate() {
            let ry = y + 4.0 + i as f32 * 30.0;
            let mut taken = chess.game.captured_by(side);
            taken.sort_by_key(|p| p.kind as u8);
            let step = self.small.size as f32 / self.canvas.scale;
            let mut x = inner.x - 3.0;
            let mut last = None;
            for p in &taken {
                // Pieces of a kind overlap; a new kind starts a little apart.
                x += if last == Some(p.kind) { step * 0.45 } else if last.is_some() { step * 0.8 } else { 0.0 };
                last = Some(p.kind);
                self.canvas.blit(self.small.get(p.color, p.kind), x, ry, 1.0);
            }
            let lead = if side == Color::White { diff } else { -diff };
            if lead > 0 {
                let tx = if taken.is_empty() { inner.x } else { x + step + 2.0 };
                self.canvas.text(fonts, Weight::Medium, 12.0, tx, ry + step * 0.68, TERTIARY, &format!("+{lead}"));
            }
        }

        self.move_list(l, chess);

        for (t, label) in [(Target::Undo, "Undo"), (Target::Flip, "Flip"), (Target::NewGame, "New Game")] {
            let Some(r) = l.rect_of(t) else { continue };
            let hovered = chess.hover == Some(t);
            let primary = t == Target::NewGame;
            let fill = match (primary, hovered) {
                (true, false) => ACCENT,
                (true, true) => rgb(0, 98, 204),
                (false, false) => FILL,
                (false, true) => rgb(222, 222, 228),
            };
            let enabled = t != Target::Undo || !chess.game.history.is_empty();
            self.canvas.round_rect(r, 10.0, fill);
            let ink = if primary { CARD } else if enabled { TEXT } else { TERTIARY };
            let (cx, cy) = r.center();
            self.canvas.text_centered(fonts, Weight::Semibold, 13.5, cx, cy + 5.0, ink, label);
        }
    }

    fn move_list(&mut self, l: &Layout, chess: &Chess) {
        let fonts = self.fonts;
        let r = l.list;
        self.canvas.round_rect(r, 10.0, rgb(247, 247, 250));
        let history = &chess.game.history;
        if history.is_empty() {
            self.canvas.text_centered(fonts, Weight::Regular, 13.0, r.center().0, r.y + 30.0, TERTIARY, "No moves yet");
            return;
        }
        // Rows of a move number, White's move and Black's; a game from a position with Black to
        // move starts with an empty White cell.
        let black_first = chess.game.start.side == Color::Black;
        let offset = black_first as usize;
        let rows = (history.len() + offset).div_ceil(2);
        let visible = ((r.h - 8.0) / l.row).floor().max(1.0) as usize;
        let first = scroll_row(chess.scroll, rows, visible);
        let col = (r.w - 44.0) / 2.0;
        for row in first..(first + visible).min(rows) {
            let y = r.y + 4.0 + (row - first) as f32 * l.row;
            let number = chess.game.start.fullmoves as usize + row;
            self.canvas.text(fonts, Weight::Regular, 13.0, r.x + 12.0, y + 18.0, TERTIARY, &format!("{number}."));
            for side in 0..2 {
                let Some(i) = (row * 2 + side).checked_sub(offset) else { continue };
                let Some(played) = history.get(i) else { continue };
                let x = r.x + 44.0 + side as f32 * col;
                let last = i + 1 == history.len();
                if last {
                    self.canvas.round_rect(Rect::new(x - 6.0, y + 3.0, col - 6.0, l.row - 4.0), 6.0, rgba(0, 113, 227, 30));
                }
                let ink = if last { ACCENT } else { TEXT };
                self.canvas.text(fonts, if last { Weight::Semibold } else { Weight::Medium }, 13.5, x, y + 18.0, ink, &played.san);
            }
        }
    }

    fn promotion(&mut self, l: &Layout, chess: &Chess) {
        let Some((from, _)) = chess.promotion else { return };
        let color = chess.game.position.at(from).map_or(Color::White, |p| p.color);
        self.canvas.fill_rect(l.board, rgba(0, 0, 0, 70));
        let cells: Vec<Rect> = Kind::PROMOTIONS.iter().filter_map(|k| l.rect_of(Target::Promote(*k))).collect();
        let (Some(a), Some(b)) = (cells.first(), cells.last()) else { return };
        let column = Rect::new(a.x, a.y.min(b.y), a.w, a.h * 4.0);
        self.canvas.shadow(column, 12.0, 14.0, rgba(0, 0, 0, 60));
        self.canvas.round_rect(column, 12.0, CARD);
        for (kind, r) in Kind::PROMOTIONS.iter().zip(&cells) {
            if chess.hover == Some(Target::Promote(*kind)) {
                self.canvas.round_rect(r.inset(4.0), 10.0, rgba(0, 113, 227, 36));
            }
            self.piece(Piece::new(color, *kind), *r, 1.0);
        }
    }

    fn result(&mut self, l: &Layout, chess: &Chess) {
        let Some(outcome) = chess.game.outcome() else { return };
        let fonts = self.fonts;
        let card = l.result_card();
        self.canvas.shadow(card, 18.0, 24.0, rgba(0, 0, 0, 60));
        self.canvas.round_rect(card, 18.0, rgba(255, 255, 255, 246));
        let (cx, _) = card.center();
        let (title, detail) = match outcome {
            Outcome::Checkmate { winner } => {
                let detail = match chess.mode {
                    Mode::Computer if winner == chess.human => "You win.".to_string(),
                    Mode::Computer => "The computer wins.".to_string(),
                    Mode::TwoPlayers => format!("{} wins.", winner.name()),
                };
                ("Checkmate".to_string(), detail)
            }
            Outcome::Stalemate => ("Stalemate".into(), "The game is drawn.".into()),
            Outcome::Repetition => ("Draw".into(), "The same position, three times.".into()),
            Outcome::FiftyMoves => ("Draw".into(), "Fifty moves without a capture or pawn move.".into()),
            Outcome::InsufficientMaterial => ("Draw".into(), "Neither side can checkmate.".into()),
        };
        self.canvas.text_centered(fonts, Weight::Semibold, 22.0, cx, card.y + 46.0, TEXT, &title);
        let size = if fonts.width(Weight::Regular, 14.0, &detail) > card.w - 32.0 { 12.5 } else { 14.0 };
        self.canvas.text_centered(fonts, Weight::Regular, size, cx, card.y + 74.0, SECONDARY, &detail);
        for (t, label, primary) in [(Target::CloseResult, "Close", false), (Target::Rematch, "New Game", true)] {
            let Some(r) = l.rect_of(t) else { continue };
            let hovered = chess.hover == Some(t);
            let fill = match (primary, hovered) {
                (true, false) => ACCENT,
                (true, true) => rgb(0, 98, 204),
                (false, false) => FILL,
                (false, true) => rgb(222, 222, 228),
            };
            self.canvas.round_rect(r, 10.0, fill);
            let (bx, by) = r.center();
            self.canvas.text_centered(fonts, Weight::Semibold, 14.0, bx, by + 5.0, if primary { CARD } else { TEXT }, label);
        }
    }
}

/// The first move-list row shown, keeping the scroll in range.
pub fn scroll_row(scroll: f32, rows: usize, visible: usize) -> usize {
    let max = rows.saturating_sub(visible);
    (scroll.max(0.0) as usize).min(max)
}

/// For a castle, where the rook goes from and to.
fn castle_rook(m: Move) -> Option<(Square, Square)> {
    match m.kind {
        MoveKind::CastleKing => Some((m.from + 3, m.from + 1)),
        MoveKind::CastleQueen => Some((m.from - 4, m.from - 1)),
        _ => None,
    }
}

fn piece_value(kind: Kind) -> i32 {
    match kind {
        Kind::Pawn => 1,
        Kind::Knight | Kind::Bishop => 3,
        Kind::Rook => 5,
        Kind::Queen => 9,
        Kind::King => 0,
    }
}

