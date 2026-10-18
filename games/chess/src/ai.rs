//! The computer player: an alpha-beta search over a material and piece-square evaluation.
//!
//! The search counts nodes rather than watching a clock, so it plays the same on any machine
//! and needs nothing from the system but memory.

use crate::rules::{Color, Kind, Move, MoveKind, Piece, Position};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// How well the computer plays.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Level {
    pub name: &'static str,
    /// The deepest the search looks, in moves by either side.
    pub depth: i32,
    /// When to stop deepening, in positions searched.
    pub nodes: u64,
    /// Centipawns of chance added to each first move's score, so weaker levels err like people.
    pub noise: i32,
}

pub const LEVELS: [Level; 4] = [
    Level { name: "Easy", depth: 1, nodes: 20_000, noise: 150 },
    Level { name: "Casual", depth: 2, nodes: 60_000, noise: 45 },
    Level { name: "Strong", depth: 5, nodes: 250_000, noise: 0 },
    Level { name: "Master", depth: 32, nodes: 3_000_000, noise: 0 },
];

const INF: i32 = 1_000_000;
const MATE: i32 = 100_000;
const MAX_PLY: usize = 96;

const VALUE: [i32; 6] = [100, 320, 330, 500, 900, 0];
/// What each piece adds to the game phase: 24 with everything on the board, 0 with only pawns.
const PHASE: [i32; 6] = [0, 1, 1, 2, 4, 0];

// Piece-square tables, in centipawns, written as White sees the board: a8 top left, h1 bottom
// right. Black reads them mirrored.
#[rustfmt::skip]
const PAWN: [i32; 64] = [
     0,  0,  0,  0,  0,  0,  0,  0,
    60, 60, 60, 60, 60, 60, 60, 60,
    15, 15, 25, 35, 35, 25, 15, 15,
     6,  6, 12, 26, 26, 12,  6,  6,
     2,  2,  6, 22, 22,  6,  2,  2,
     4, -2, -6,  4,  4, -6, -2,  4,
     4,  8,  8,-18,-18,  8,  8,  4,
     0,  0,  0,  0,  0,  0,  0,  0,
];
#[rustfmt::skip]
const PAWN_END: [i32; 64] = [
     0,  0,  0,  0,  0,  0,  0,  0,
    90, 90, 90, 90, 90, 90, 90, 90,
    55, 55, 55, 55, 55, 55, 55, 55,
    30, 30, 30, 30, 30, 30, 30, 30,
    15, 15, 15, 15, 15, 15, 15, 15,
     5,  5,  5,  5,  5,  5,  5,  5,
     0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,
];
#[rustfmt::skip]
const KNIGHT: [i32; 64] = [
    -50,-35,-25,-25,-25,-25,-35,-50,
    -35,-15,  0,  5,  5,  0,-15,-35,
    -25,  5, 12, 16, 16, 12,  5,-25,
    -25,  5, 16, 22, 22, 16,  5,-25,
    -25,  0, 16, 22, 22, 16,  0,-25,
    -25,  5, 12, 14, 14, 12,  5,-25,
    -35,-15,  0,  5,  5,  0,-15,-35,
    -50,-30,-25,-25,-25,-25,-30,-50,
];
#[rustfmt::skip]
const BISHOP: [i32; 64] = [
    -20,-10,-10,-10,-10,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  6, 10, 10,  6,  0,-10,
    -10,  6,  6, 12, 12,  6,  6,-10,
    -10,  0, 12, 12, 12, 12,  0,-10,
    -10, 10, 10, 10, 10, 10, 10,-10,
    -10,  8,  0,  2,  2,  0,  8,-10,
    -20,-10,-12,-10,-10,-12,-10,-20,
];
#[rustfmt::skip]
const ROOK: [i32; 64] = [
      0,  0,  0,  4,  4,  0,  0,  0,
     12, 16, 16, 16, 16, 16, 16, 12,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
      0,  0,  2,  8,  8,  4,  0,  0,
];
#[rustfmt::skip]
const QUEEN: [i32; 64] = [
    -20,-10,-10, -5, -5,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5,  5,  5,  5,  0,-10,
     -5,  0,  5,  5,  5,  5,  0, -5,
     -5,  0,  5,  5,  5,  5,  0, -5,
    -10,  4,  5,  5,  5,  5,  0,-10,
    -10,  0,  4,  0,  0,  0,  0,-10,
    -20,-10,-10, -2, -5,-10,-10,-20,
];
#[rustfmt::skip]
const KING: [i32; 64] = [
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -20,-30,-30,-40,-40,-30,-30,-20,
    -10,-20,-20,-24,-24,-20,-20,-10,
     14, 14, -4, -8, -8, -4, 14, 14,
     16, 28, 12, -4,  0,  6, 30, 18,
];
#[rustfmt::skip]
const KING_END: [i32; 64] = [
    -50,-35,-25,-20,-20,-25,-35,-50,
    -30,-15, -5,  0,  0, -5,-15,-30,
    -25, -5, 18, 26, 26, 18, -5,-25,
    -25, -5, 26, 36, 36, 26, -5,-25,
    -25, -5, 26, 36, 36, 26, -5,-25,
    -25, -5, 18, 26, 26, 18, -5,-25,
    -30,-25,  0,  0,  0,  0,-25,-30,
    -50,-35,-30,-30,-30,-30,-35,-50,
];

fn table(kind: Kind, end: bool) -> &'static [i32; 64] {
    match (kind, end) {
        (Kind::Pawn, false) => &PAWN,
        (Kind::Pawn, true) => &PAWN_END,
        (Kind::Knight, _) => &KNIGHT,
        (Kind::Bishop, _) => &BISHOP,
        (Kind::Rook, _) => &ROOK,
        (Kind::Queen, _) => &QUEEN,
        (Kind::King, false) => &KING,
        (Kind::King, true) => &KING_END,
    }
}

/// The position's worth to the side to move, in centipawns.
pub fn evaluate(pos: &Position) -> i32 {
    let mut mid = [0i32; 2];
    let mut end = [0i32; 2];
    let mut phase = 0;
    let mut bishops = [0; 2];
    for sq in 0..64u8 {
        let Some(p) = pos.at(sq) else { continue };
        let c = p.color.index();
        let k = p.kind as usize;
        // The tables list a8 first, so White flips the rank and Black reads them as they stand.
        let i = if p.color == Color::White { sq ^ 56 } else { sq } as usize;
        mid[c] += VALUE[k] + table(p.kind, false)[i];
        end[c] += VALUE[k] + table(p.kind, true)[i];
        phase += PHASE[k];
        if p.kind == Kind::Bishop {
            bishops[c] += 1;
        }
    }
    for c in 0..2 {
        if bishops[c] >= 2 {
            mid[c] += 30;
            end[c] += 45;
        }
    }
    let phase = phase.min(24);
    let white = ((mid[0] - mid[1]) * phase + (end[0] - end[1]) * (24 - phase)) / 24;
    if pos.side == Color::White { white } else { -white }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Bound {
    Exact,
    Lower,
    Upper,
}

#[derive(Clone, Copy)]
struct Entry {
    key: u64,
    mv: Option<Move>,
    score: i32,
    depth: i32,
    bound: Bound,
}

const TT_SIZE: usize = 1 << 19;

/// The search's tables, kept between iterations.
struct Searcher {
    tt: Vec<Option<Entry>>,
    killers: [[Option<Move>; 2]; MAX_PLY],
    history: [[i32; 64]; 64],
    /// Hashes of the game's positions, then the positions on the path being searched.
    path: Vec<u64>,
    nodes: u64,
    limit: u64,
    /// Where this step's slice of nodes ends.
    slice_end: u64,
    stopped: bool,
    /// Set from outside to end the search early.
    cancel: Arc<AtomicBool>,
    /// Whether the search stopped for the slice rather than the limit.
    paused: bool,
    rng: u64,
}

/// What the search found.
#[derive(Clone, Copy, Debug)]
pub struct Found {
    pub mv: Move,
    pub score: i32,
    pub depth: i32,
    pub nodes: u64,
}

/// The move the computer plays at `level`. `history` holds the hashes of the positions before
/// this one, to steer clear of or towards repeats; `seed` varies the weaker levels' choices.
pub fn choose(pos: &Position, history: &[u64], level: Level, seed: u64) -> Option<Found> {
    let mut search = Search::new(pos, history, level, seed);
    while !search.step() {}
    search.result()
}

/// A search that runs a piece at a time: each [`Search::step`] searches one first move. Where
/// there is only one thread, the game steps it between frames, so the window stays responsive.
pub struct Search {
    searcher: Searcher,
    pos: Position,
    level: Level,
    moves: Vec<Move>,
    noise: Vec<i32>,
    /// The first moves in the order to search them: the last iteration's best first.
    order: Vec<usize>,
    depth: i32,
    /// Where this iteration is in `order`.
    next: usize,
    alpha: i32,
    /// The best first move of this iteration so far, and its score.
    found: Option<(usize, i32)>,
    best: Option<Found>,
    done: bool,
    /// The most nodes a step may search before it pauses, if steps are sliced.
    slice: Option<u64>,
    /// The slice for the next step: it doubles each time a step pauses, so every step ends.
    this_slice: u64,
}

impl Search {
    pub fn new(pos: &Position, history: &[u64], level: Level, seed: u64) -> Search {
        let mut searcher = Searcher::new(history, seed);
        searcher.limit = level.nodes;
        searcher.path.push(pos.hash);
        let moves = pos.legal_moves();
        let noise = moves
            .iter()
            .map(|_| {
                if level.noise == 0 {
                    0
                } else {
                    (searcher.random() % (2 * level.noise as u64 + 1)) as i32 - level.noise
                }
            })
            .collect();
        Search {
            order: (0..moves.len()).collect(),
            done: moves.is_empty(),
            searcher,
            pos: *pos,
            level,
            moves,
            noise,
            depth: 1,
            next: 0,
            alpha: -INF,
            found: None,
            best: None,
            slice: None,
            this_slice: 0,
        }
    }

    /// Makes each step stop after about `nodes` positions and pick up again on the next, so no
    /// step stalls the caller for long. A paused step searches again from its first move, but
    /// the transposition table remembers most of what it found.
    pub fn sliced(mut self, nodes: u64) -> Search {
        self.slice = Some(nodes);
        self.this_slice = nodes;
        self
    }

    /// A flag that ends the search at its next check when set, from any thread.
    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.searcher.cancel.clone()
    }

    /// Searches the next first move; true once the search is over.
    pub fn step(&mut self) -> bool {
        if self.done {
            return true;
        }
        let i = self.order[self.next];
        let next = self.pos.make(self.moves[i]);
        let s = &mut self.searcher;
        s.slice_end = self.slice.map_or(u64::MAX, |_| s.nodes + self.this_slice);
        s.path.push(next.hash);
        // With noise, every move needs its true score, so none is cut against the best.
        let floor = if self.level.noise > 0 { -INF } else { self.alpha };
        let score = -s.search(&next, self.depth - 1, 1, -INF, -floor) + self.noise[i];
        s.path.pop();
        if s.paused {
            s.stopped = false;
            s.paused = false;
            self.this_slice += self.this_slice / 2;
            return false;
        }
        if let Some(slice) = self.slice {
            self.this_slice = slice;
        }
        if s.stopped {
            // Out of nodes: keep the last whole iteration's answer, if there is one.
            if self.best.is_none() {
                self.finish_iteration();
            }
            self.done = true;
            return true;
        }
        if self.found.is_none_or(|(_, best)| score > best) {
            self.found = Some((i, score));
            self.alpha = self.alpha.max(score);
        }
        self.next += 1;
        if self.next == self.order.len() {
            let mate = self.finish_iteration();
            self.depth += 1;
            self.next = 0;
            self.alpha = -INF;
            self.done = mate || self.depth > self.level.depth;
        }
        self.done
    }

    /// Takes the iteration's best move as the answer so far; true if it mates.
    fn finish_iteration(&mut self) -> bool {
        let Some((i, score)) = self.found.take() else { return false };
        self.best = Some(Found { mv: self.moves[i], score, depth: self.depth, nodes: self.searcher.nodes });
        // Search the best move first next time.
        self.order.retain(|&j| j != i);
        self.order.insert(0, i);
        score.abs() >= MATE - MAX_PLY as i32
    }

    /// The move to play, once [`Search::step`] says the search is over.
    pub fn result(&self) -> Option<Found> {
        self.best.map(|b| Found { nodes: self.searcher.nodes, ..b })
    }
}

impl Searcher {
    fn new(history: &[u64], seed: u64) -> Searcher {
        Searcher {
            tt: vec![None; TT_SIZE],
            killers: [[None; 2]; MAX_PLY],
            history: [[0; 64]; 64],
            path: history.to_vec(),
            nodes: 0,
            limit: u64::MAX,
            slice_end: u64::MAX,
            stopped: false,
            cancel: Arc::new(AtomicBool::new(false)),
            paused: false,
            rng: seed | 1,
        }
    }

    fn random(&mut self) -> u64 {
        // xorshift64
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        self.rng
    }

    fn repeated(&self, pos: &Position) -> bool {
        // Only positions since the last capture or pawn move can repeat; the newest is this one.
        let n = self.path.len();
        let span = (pos.halfmoves as usize + 1).min(n);
        self.path[n - span..n - 1].iter().rev().skip(1).step_by(2).any(|&h| h == pos.hash)
    }

    fn search(&mut self, pos: &Position, depth: i32, ply: usize, mut alpha: i32, beta: i32) -> i32 {
        self.nodes += 1;
        if self.nodes >= self.limit || (self.nodes & 1023 == 0 && self.cancel.load(Ordering::Relaxed)) {
            self.stopped = true;
        } else if self.nodes >= self.slice_end {
            self.stopped = true;
            self.paused = true;
        }
        if self.stopped {
            return 0;
        }
        if pos.halfmoves >= 100 || self.repeated(pos) || pos.insufficient_material() {
            return 0;
        }
        if ply >= MAX_PLY - 1 {
            return evaluate(pos);
        }
        let in_check = pos.in_check();
        let depth = if in_check { depth + 1 } else { depth };
        if depth <= 0 {
            return self.quiesce(pos, ply, alpha, beta);
        }

        let slot = (pos.hash as usize) & (TT_SIZE - 1);
        let mut tt_move = None;
        if let Some(e) = self.tt[slot].filter(|e| e.key == pos.hash) {
            tt_move = e.mv;
            if e.depth >= depth {
                let score = from_tt(e.score, ply);
                match e.bound {
                    Bound::Exact => return score,
                    Bound::Lower if score >= beta => return score,
                    Bound::Upper if score <= alpha => return score,
                    _ => {}
                }
            }
        }

        // Passing is never better than the best move, so if passing still beats beta, a real
        // search would too. Unsafe in pawn endings, where passing can be the only good move.
        if !in_check && depth >= 3 && beta.abs() < MATE - MAX_PLY as i32 && has_pieces(pos) {
            let next = pos.make_null();
            self.path.push(next.hash);
            let score = -self.search(&next, depth - 3, ply + 1, -beta, -beta + 1);
            self.path.pop();
            if self.stopped {
                return 0;
            }
            if score >= beta {
                return beta;
            }
        }

        let mut moves = Vec::with_capacity(48);
        pos.pseudo_moves(&mut moves);
        let mut scores: Vec<i32> = moves.iter().map(|&m| self.order_score(pos, m, tt_move, ply)).collect();

        let original_alpha = alpha;
        let mut best = -INF;
        let mut best_move = None;
        let mut legal = 0;
        for k in 0..moves.len() {
            pick_next(&mut moves, &mut scores, k);
            let m = moves[k];
            let next = pos.make(m);
            if next.attacked(next.king(pos.side), next.side) {
                continue;
            }
            legal += 1;
            self.path.push(next.hash);
            let score = -self.search(&next, depth - 1, ply + 1, -beta, -alpha);
            self.path.pop();
            if self.stopped {
                return 0;
            }
            if score > best {
                best = score;
                best_move = Some(m);
                if score > alpha {
                    alpha = score;
                    if alpha >= beta {
                        if !m.is_capture() && m.promotion.is_none() {
                            let k = &mut self.killers[ply];
                            if k[0] != Some(m) {
                                k[1] = k[0];
                                k[0] = Some(m);
                            }
                            self.history[m.from as usize][m.to as usize] += depth * depth;
                        }
                        break;
                    }
                }
            }
        }
        if legal == 0 {
            return if in_check { -MATE + ply as i32 } else { 0 };
        }
        let bound = if best >= beta {
            Bound::Lower
        } else if best > original_alpha {
            Bound::Exact
        } else {
            Bound::Upper
        };
        self.tt[slot] = Some(Entry { key: pos.hash, mv: best_move, score: to_tt(best, ply), depth, bound });
        best
    }

    /// Searches only captures and promotions, so the evaluation never stops mid-exchange.
    fn quiesce(&mut self, pos: &Position, ply: usize, mut alpha: i32, beta: i32) -> i32 {
        self.nodes += 1;
        let stand = evaluate(pos);
        if stand >= beta {
            return stand;
        }
        alpha = alpha.max(stand);
        if ply >= MAX_PLY - 1 {
            return stand;
        }
        let mut moves = Vec::with_capacity(16);
        pos.pseudo_moves(&mut moves);
        moves.retain(|m| m.is_capture() || m.promotion == Some(Kind::Queen));
        let mut scores: Vec<i32> = moves.iter().map(|&m| mvv_lva(pos, m)).collect();
        let mut best = stand;
        for k in 0..moves.len() {
            pick_next(&mut moves, &mut scores, k);
            let m = moves[k];
            let next = pos.make(m);
            if next.attacked(next.king(pos.side), next.side) {
                continue;
            }
            let score = -self.quiesce(&next, ply + 1, -beta, -alpha);
            if score > best {
                best = score;
                if score > alpha {
                    alpha = score;
                    if alpha >= beta {
                        break;
                    }
                }
            }
        }
        best
    }

    fn order_score(&self, pos: &Position, m: Move, tt_move: Option<Move>, ply: usize) -> i32 {
        if Some(m) == tt_move {
            return 10_000_000;
        }
        if m.is_capture() || m.promotion.is_some() {
            return 1_000_000 + mvv_lva(pos, m);
        }
        if self.killers[ply][0] == Some(m) {
            return 900_000;
        }
        if self.killers[ply][1] == Some(m) {
            return 800_000;
        }
        self.history[m.from as usize][m.to as usize].min(700_000)
    }
}

/// Most valuable victim, least valuable attacker: taking a queen with a pawn first.
fn mvv_lva(pos: &Position, m: Move) -> i32 {
    let victim = match m.kind {
        MoveKind::EnPassant => VALUE[Kind::Pawn as usize],
        _ => pos.at(m.to).map_or(0, |p| VALUE[p.kind as usize]),
    };
    let attacker = pos.at(m.from).map_or(0, |p| VALUE[p.kind as usize]);
    let promotion = m.promotion.map_or(0, |k| VALUE[k as usize]);
    victim * 10 + promotion * 10 - attacker / 10
}

/// Moves the best-scored of the moves from `k` on to `k`: a selection sort, done only as far as
/// the search gets before a cutoff.
fn pick_next(moves: &mut [Move], scores: &mut [i32], k: usize) {
    let mut best = k;
    for j in k + 1..moves.len() {
        if scores[j] > scores[best] {
            best = j;
        }
    }
    moves.swap(k, best);
    scores.swap(k, best);
}

fn has_pieces(pos: &Position) -> bool {
    (0..64u8).any(|sq| {
        pos.at(sq).is_some_and(|p: Piece| {
            p.color == pos.side && !matches!(p.kind, Kind::Pawn | Kind::King)
        })
    })
}

/// Mate scores count from the root; the table stores them counted from the position instead.
fn to_tt(score: i32, ply: usize) -> i32 {
    if score > MATE - MAX_PLY as i32 {
        score + ply as i32
    } else if score < -MATE + MAX_PLY as i32 {
        score - ply as i32
    } else {
        score
    }
}

fn from_tt(score: i32, ply: usize) -> i32 {
    if score > MATE - MAX_PLY as i32 {
        score - ply as i32
    } else if score < -MATE + MAX_PLY as i32 {
        score + ply as i32
    } else {
        score
    }
}

/// Whether `score` says a side mates, and in how many of its own moves.
pub fn mate_in(score: i32) -> Option<i32> {
    if score.abs() > MATE - MAX_PLY as i32 {
        let plies = MATE - score.abs();
        Some((plies + 1) / 2 * score.signum())
    } else {
        None
    }
}
