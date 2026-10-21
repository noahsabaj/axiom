//! The rules of chess: the board, the moves, and what ends a game.
//!
//! Nothing here knows about the engine, so the tests run without a window.

use std::fmt::Write as _;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Color {
    White,
    Black,
}

impl Color {
    pub fn other(self) -> Color {
        match self {
            Color::White => Color::Black,
            Color::Black => Color::White,
        }
    }

    pub fn index(self) -> usize {
        self as usize
    }

    pub fn name(self) -> &'static str {
        match self {
            Color::White => "White",
            Color::Black => "Black",
        }
    }

    /// Which way this side's pawns walk, in ranks.
    fn forward(self) -> i8 {
        match self {
            Color::White => 1,
            Color::Black => -1,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Kind {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
}

impl Kind {
    pub const PROMOTIONS: [Kind; 4] = [Kind::Queen, Kind::Rook, Kind::Bishop, Kind::Knight];

    /// The letter algebraic notation uses for this piece; none for a pawn.
    pub fn letter(self) -> &'static str {
        match self {
            Kind::Pawn => "",
            Kind::Knight => "N",
            Kind::Bishop => "B",
            Kind::Rook => "R",
            Kind::Queen => "Q",
            Kind::King => "K",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct Piece {
    pub color: Color,
    pub kind: Kind,
}

impl Piece {
    pub const fn new(color: Color, kind: Kind) -> Piece {
        Piece { color, kind }
    }

    fn from_fen(c: char) -> Option<Piece> {
        let color = if c.is_ascii_uppercase() { Color::White } else { Color::Black };
        let kind = match c.to_ascii_lowercase() {
            'p' => Kind::Pawn,
            'n' => Kind::Knight,
            'b' => Kind::Bishop,
            'r' => Kind::Rook,
            'q' => Kind::Queen,
            'k' => Kind::King,
            _ => return None,
        };
        Some(Piece::new(color, kind))
    }

    fn fen(self) -> char {
        let c = match self.kind {
            Kind::Pawn => 'p',
            Kind::Knight => 'n',
            Kind::Bishop => 'b',
            Kind::Rook => 'r',
            Kind::Queen => 'q',
            Kind::King => 'k',
        };
        if self.color == Color::White { c.to_ascii_uppercase() } else { c }
    }

    fn zobrist_index(self, sq: Square) -> usize {
        (self.color.index() * 6 + self.kind as usize) * 64 + sq as usize
    }
}

/// A square, 0 = a1 to 63 = h8: `rank * 8 + file`.
pub type Square = u8;

pub fn file_of(sq: Square) -> u8 {
    sq & 7
}

pub fn rank_of(sq: Square) -> u8 {
    sq >> 3
}

pub fn square(file: u8, rank: u8) -> Square {
    rank * 8 + file
}

pub fn square_name(sq: Square) -> String {
    format!("{}{}", (b'a' + file_of(sq)) as char, rank_of(sq) + 1)
}

pub fn parse_square(s: &str) -> Option<Square> {
    let b = s.as_bytes();
    if b.len() != 2 || !(b'a'..=b'h').contains(&b[0]) || !(b'1'..=b'8').contains(&b[1]) {
        return None;
    }
    Some(square(b[0] - b'a', b[1] - b'1'))
}

/// The square `df` files and `dr` ranks away, if it is on the board.
fn offset(sq: Square, df: i8, dr: i8) -> Option<Square> {
    let f = file_of(sq) as i8 + df;
    let r = rank_of(sq) as i8 + dr;
    if (0..8).contains(&f) && (0..8).contains(&r) {
        Some(square(f as u8, r as u8))
    } else {
        None
    }
}

const KNIGHT: [(i8, i8); 8] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)];
const KING: [(i8, i8); 8] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)];
const DIAGONAL: [(i8, i8); 4] = [(1, 1), (-1, 1), (-1, -1), (1, -1)];
const STRAIGHT: [(i8, i8); 4] = [(1, 0), (0, 1), (-1, 0), (0, -1)];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MoveKind {
    Quiet,
    Capture,
    DoublePush,
    EnPassant,
    CastleKing,
    CastleQueen,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Move {
    pub from: Square,
    pub to: Square,
    pub kind: MoveKind,
    pub promotion: Option<Kind>,
}

impl Move {
    pub fn is_capture(self) -> bool {
        matches!(self.kind, MoveKind::Capture | MoveKind::EnPassant)
    }

    /// The move in coordinates, such as `e2e4` or `e7e8q`.
    pub fn uci(self) -> String {
        let mut s = square_name(self.from) + &square_name(self.to);
        if let Some(k) = self.promotion {
            s.push(k.letter().to_ascii_lowercase().chars().next().unwrap());
        }
        s
    }
}

// Castling rights, one bit each.
pub const WHITE_SHORT: u8 = 1;
pub const WHITE_LONG: u8 = 2;
pub const BLACK_SHORT: u8 = 4;
pub const BLACK_LONG: u8 = 8;

/// The rights that survive a move from or to each square: moving a king or a rook, or capturing a
/// rook at home, loses them.
const CASTLE_MASK: [u8; 64] = {
    let mut m = [0xF; 64];
    m[0] = !WHITE_LONG & 0xF;
    m[4] = !(WHITE_SHORT | WHITE_LONG) & 0xF;
    m[7] = !WHITE_SHORT & 0xF;
    m[56] = !BLACK_LONG & 0xF;
    m[60] = !(BLACK_SHORT | BLACK_LONG) & 0xF;
    m[63] = !BLACK_SHORT & 0xF;
    m
};

const fn splitmix(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

const Z_SIDE: usize = 768;
const Z_CASTLE: usize = 769;
const Z_EP: usize = 785;
const ZOBRIST: [u64; 793] = {
    let mut t = [0u64; 793];
    let mut i = 0;
    while i < t.len() {
        t[i] = splitmix((i as u64).wrapping_mul(0x2545_F491_4F6C_DD1D).wrapping_add(0x1234_5678));
        i += 1;
    }
    t
};

pub const START_FEN: &str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

/// A position: where the pieces stand, who moves, and the rights that aren't on the board.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Position {
    pub board: [Option<Piece>; 64],
    pub side: Color,
    pub castling: u8,
    /// The square a pawn passed over on the last move, when a pawn could take it there.
    pub en_passant: Option<Square>,
    /// Moves since the last capture or pawn move, for the fifty-move rule.
    pub halfmoves: u32,
    pub fullmoves: u32,
    /// Zobrist hash of everything above but the move counters.
    pub hash: u64,
    kings: [Square; 2],
}

impl Default for Position {
    fn default() -> Self {
        Position::start()
    }
}

impl Position {
    pub fn start() -> Position {
        Position::from_fen(START_FEN).unwrap()
    }

    pub fn from_fen(fen: &str) -> Result<Position, String> {
        let mut parts = fen.split_whitespace();
        let placement = parts.next().ok_or("empty FEN")?;
        let mut p = Position {
            board: [None; 64],
            side: Color::White,
            castling: 0,
            en_passant: None,
            halfmoves: 0,
            fullmoves: 1,
            hash: 0,
            kings: [64; 2],
        };
        let rows: Vec<&str> = placement.split('/').collect();
        if rows.len() != 8 {
            return Err(format!("need 8 ranks, got {}", rows.len()));
        }
        for (i, row) in rows.iter().enumerate() {
            let rank = 7 - i as u8;
            let mut file = 0u8;
            for c in row.chars() {
                if let Some(d) = c.to_digit(10) {
                    file += d as u8;
                } else {
                    let piece = Piece::from_fen(c).ok_or(format!("bad piece '{c}'"))?;
                    if file > 7 {
                        return Err(format!("rank {} is too long", rank + 1));
                    }
                    p.put(square(file, rank), piece);
                    file += 1;
                }
            }
            if file != 8 {
                return Err(format!("rank {} has {} files", rank + 1, file));
            }
        }
        if p.kings.contains(&64) {
            return Err("each side needs a king".into());
        }
        match parts.next().unwrap_or("w") {
            "w" => {}
            "b" => {
                p.side = Color::Black;
                p.hash ^= ZOBRIST[Z_SIDE];
            }
            s => return Err(format!("bad side '{s}'")),
        }
        for c in parts.next().unwrap_or("-").chars() {
            p.castling |= match c {
                'K' => WHITE_SHORT,
                'Q' => WHITE_LONG,
                'k' => BLACK_SHORT,
                'q' => BLACK_LONG,
                '-' => 0,
                _ => return Err(format!("bad castling '{c}'")),
            };
        }
        p.hash ^= ZOBRIST[Z_CASTLE + p.castling as usize];
        match parts.next().unwrap_or("-") {
            "-" => {}
            s => p.set_en_passant(parse_square(s).ok_or(format!("bad en passant '{s}'"))?),
        }
        p.halfmoves = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        p.fullmoves = parts.next().and_then(|s| s.parse().ok()).unwrap_or(1);
        Ok(p)
    }

    pub fn fen(&self) -> String {
        let mut s = String::new();
        for rank in (0..8).rev() {
            let mut empty = 0;
            for file in 0..8 {
                match self.board[square(file, rank) as usize] {
                    None => empty += 1,
                    Some(p) => {
                        if empty > 0 {
                            write!(s, "{empty}").unwrap();
                            empty = 0;
                        }
                        s.push(p.fen());
                    }
                }
            }
            if empty > 0 {
                write!(s, "{empty}").unwrap();
            }
            if rank > 0 {
                s.push('/');
            }
        }
        s.push_str(if self.side == Color::White { " w " } else { " b " });
        if self.castling == 0 {
            s.push('-');
        }
        for (bit, c) in [(WHITE_SHORT, 'K'), (WHITE_LONG, 'Q'), (BLACK_SHORT, 'k'), (BLACK_LONG, 'q')] {
            if self.castling & bit != 0 {
                s.push(c);
            }
        }
        match self.en_passant {
            Some(sq) => write!(s, " {}", square_name(sq)).unwrap(),
            None => s.push_str(" -"),
        }
        write!(s, " {} {}", self.halfmoves, self.fullmoves).unwrap();
        s
    }

    pub fn at(&self, sq: Square) -> Option<Piece> {
        self.board[sq as usize]
    }

    pub fn king(&self, color: Color) -> Square {
        self.kings[color.index()]
    }

    fn put(&mut self, sq: Square, piece: Piece) {
        debug_assert!(self.board[sq as usize].is_none());
        self.board[sq as usize] = Some(piece);
        self.hash ^= ZOBRIST[piece.zobrist_index(sq)];
        if piece.kind == Kind::King {
            self.kings[piece.color.index()] = sq;
        }
    }

    fn take(&mut self, sq: Square) -> Option<Piece> {
        let piece = self.board[sq as usize].take()?;
        self.hash ^= ZOBRIST[piece.zobrist_index(sq)];
        Some(piece)
    }

    /// Records the square a pawn just passed over, but only when an enemy pawn stands ready to
    /// take there, so positions that differ in nothing else hash alike.
    fn set_en_passant(&mut self, sq: Square) {
        let taker = self.side;
        let behind = -taker.forward();
        let attacked = [-1, 1].iter().any(|&df| {
            offset(sq, df, behind)
                .and_then(|s| self.at(s))
                .is_some_and(|p| p == Piece::new(taker, Kind::Pawn))
        });
        if attacked {
            self.en_passant = Some(sq);
            self.hash ^= ZOBRIST[Z_EP + file_of(sq) as usize];
        }
    }

    /// Whether `by` attacks `sq`.
    pub fn attacked(&self, sq: Square, by: Color) -> bool {
        let is = |s: Option<Square>, kind: Kind| s.and_then(|s| self.at(s)) == Some(Piece::new(by, kind));
        let behind = -by.forward();
        if is(offset(sq, -1, behind), Kind::Pawn) || is(offset(sq, 1, behind), Kind::Pawn) {
            return true;
        }
        if KNIGHT.iter().any(|&(df, dr)| is(offset(sq, df, dr), Kind::Knight)) {
            return true;
        }
        if KING.iter().any(|&(df, dr)| is(offset(sq, df, dr), Kind::King)) {
            return true;
        }
        for (dirs, kind) in [(DIAGONAL, Kind::Bishop), (STRAIGHT, Kind::Rook)] {
            for (df, dr) in dirs {
                let mut s = sq;
                while let Some(next) = offset(s, df, dr) {
                    s = next;
                    if let Some(p) = self.at(s) {
                        if p.color == by && (p.kind == kind || p.kind == Kind::Queen) {
                            return true;
                        }
                        break;
                    }
                }
            }
        }
        false
    }

    pub fn in_check(&self) -> bool {
        self.attacked(self.king(self.side), self.side.other())
    }

    /// Moves that follow how the pieces move, some of which may leave the king in check.
    pub fn pseudo_moves(&self, out: &mut Vec<Move>) {
        let us = self.side;
        for from in 0..64u8 {
            let Some(piece) = self.at(from) else { continue };
            if piece.color != us {
                continue;
            }
            match piece.kind {
                Kind::Pawn => self.pawn_moves(from, out),
                Kind::Knight => self.step_moves(from, &KNIGHT, out),
                Kind::King => {
                    self.step_moves(from, &KING, out);
                    self.castle_moves(from, out);
                }
                Kind::Bishop => self.slide_moves(from, &DIAGONAL, out),
                Kind::Rook => self.slide_moves(from, &STRAIGHT, out),
                Kind::Queen => {
                    self.slide_moves(from, &DIAGONAL, out);
                    self.slide_moves(from, &STRAIGHT, out);
                }
            }
        }
    }

    fn pawn_moves(&self, from: Square, out: &mut Vec<Move>) {
        let us = self.side;
        let fwd = us.forward();
        let home = if us == Color::White { 1 } else { 6 };
        let last = if us == Color::White { 7 } else { 0 };
        let mut push = |to: Square, kind: MoveKind| {
            if rank_of(to) == last {
                for k in Kind::PROMOTIONS {
                    out.push(Move { from, to, kind, promotion: Some(k) });
                }
            } else {
                out.push(Move { from, to, kind, promotion: None });
            }
        };
        if let Some(one) = offset(from, 0, fwd).filter(|&s| self.at(s).is_none()) {
            push(one, MoveKind::Quiet);
            if rank_of(from) == home
                && let Some(two) = offset(one, 0, fwd).filter(|&s| self.at(s).is_none())
            {
                push(two, MoveKind::DoublePush);
            }
        }
        for df in [-1, 1] {
            let Some(to) = offset(from, df, fwd) else { continue };
            match self.at(to) {
                Some(p) if p.color != us => push(to, MoveKind::Capture),
                None if self.en_passant == Some(to) => push(to, MoveKind::EnPassant),
                _ => {}
            }
        }
    }

    fn step_moves(&self, from: Square, steps: &[(i8, i8)], out: &mut Vec<Move>) {
        for &(df, dr) in steps {
            let Some(to) = offset(from, df, dr) else { continue };
            match self.at(to) {
                None => out.push(Move { from, to, kind: MoveKind::Quiet, promotion: None }),
                Some(p) if p.color != self.side => {
                    out.push(Move { from, to, kind: MoveKind::Capture, promotion: None })
                }
                _ => {}
            }
        }
    }

    fn slide_moves(&self, from: Square, dirs: &[(i8, i8)], out: &mut Vec<Move>) {
        for &(df, dr) in dirs {
            let mut s = from;
            while let Some(to) = offset(s, df, dr) {
                s = to;
                match self.at(to) {
                    None => out.push(Move { from, to, kind: MoveKind::Quiet, promotion: None }),
                    Some(p) => {
                        if p.color != self.side {
                            out.push(Move { from, to, kind: MoveKind::Capture, promotion: None });
                        }
                        break;
                    }
                }
            }
        }
    }

    fn castle_moves(&self, from: Square, out: &mut Vec<Move>) {
        let us = self.side;
        let (short, long, home) = match us {
            Color::White => (WHITE_SHORT, WHITE_LONG, 4),
            Color::Black => (BLACK_SHORT, BLACK_LONG, 60),
        };
        if from != home || self.castling & (short | long) == 0 {
            return;
        }
        let them = us.other();
        let empty = |s: Square| self.at(s).is_none();
        let safe = |s: Square| !self.attacked(s, them);
        let rook = Some(Piece::new(us, Kind::Rook));
        if self.castling & short != 0
            && self.at(home + 3) == rook
            && empty(home + 1)
            && empty(home + 2)
            && safe(home)
            && safe(home + 1)
            && safe(home + 2)
        {
            out.push(Move { from, to: home + 2, kind: MoveKind::CastleKing, promotion: None });
        }
        if self.castling & long != 0
            && self.at(home - 4) == rook
            && empty(home - 1)
            && empty(home - 2)
            && empty(home - 3)
            && safe(home)
            && safe(home - 1)
            && safe(home - 2)
        {
            out.push(Move { from, to: home - 2, kind: MoveKind::CastleQueen, promotion: None });
        }
    }

    /// The position after `m`, which must be one of [`Position::pseudo_moves`].
    pub fn make(&self, m: Move) -> Position {
        let mut p = *self;
        let us = self.side;
        let piece = p.take(m.from).expect("a move starts on a piece");
        p.halfmoves += 1;
        if piece.kind == Kind::Pawn {
            p.halfmoves = 0;
        }
        match m.kind {
            MoveKind::Capture => {
                p.take(m.to);
                p.halfmoves = 0;
            }
            MoveKind::EnPassant => {
                p.take(square(file_of(m.to), rank_of(m.from)));
                p.halfmoves = 0;
            }
            MoveKind::CastleKing => {
                let rook = p.take(m.from + 3).unwrap();
                p.put(m.from + 1, rook);
            }
            MoveKind::CastleQueen => {
                let rook = p.take(m.from - 4).unwrap();
                p.put(m.from - 1, rook);
            }
            MoveKind::Quiet | MoveKind::DoublePush => {}
        }
        p.put(m.to, Piece::new(us, m.promotion.unwrap_or(piece.kind)));

        if let Some(sq) = p.en_passant.take() {
            p.hash ^= ZOBRIST[Z_EP + file_of(sq) as usize];
        }
        p.hash ^= ZOBRIST[Z_CASTLE + p.castling as usize];
        p.castling &= CASTLE_MASK[m.from as usize] & CASTLE_MASK[m.to as usize];
        p.hash ^= ZOBRIST[Z_CASTLE + p.castling as usize];

        if us == Color::Black {
            p.fullmoves += 1;
        }
        p.side = us.other();
        p.hash ^= ZOBRIST[Z_SIDE];
        if m.kind == MoveKind::DoublePush {
            p.set_en_passant(square(file_of(m.from), (rank_of(m.from) + rank_of(m.to)) / 2));
        }
        p
    }

    /// The position with the turn passed to the other side, for the search's null-move test.
    pub fn make_null(&self) -> Position {
        let mut p = *self;
        if let Some(sq) = p.en_passant.take() {
            p.hash ^= ZOBRIST[Z_EP + file_of(sq) as usize];
        }
        p.side = self.side.other();
        p.hash ^= ZOBRIST[Z_SIDE];
        p.halfmoves += 1;
        p
    }

    /// The moves the side to move may play.
    pub fn legal_moves(&self) -> Vec<Move> {
        let mut moves = Vec::with_capacity(48);
        self.pseudo_moves(&mut moves);
        moves.retain(|&m| self.is_legal_pseudo(m));
        moves
    }

    /// Whether a move from [`Position::pseudo_moves`] keeps the mover's king out of check.
    pub fn is_legal_pseudo(&self, m: Move) -> bool {
        let next = self.make(m);
        !next.attacked(next.king(self.side), next.side)
    }

    /// Neither side can mate by any series of moves: king against king, with at most a lone
    /// knight or bishops all on one colour of square.
    pub fn insufficient_material(&self) -> bool {
        let mut minors = 0;
        let mut knights = 0;
        let mut bishop_colors = [false; 2];
        for sq in 0..64u8 {
            match self.at(sq).map(|p| p.kind) {
                None | Some(Kind::King) => {}
                Some(Kind::Knight) => {
                    minors += 1;
                    knights += 1;
                }
                Some(Kind::Bishop) => {
                    minors += 1;
                    bishop_colors[((file_of(sq) + rank_of(sq)) % 2) as usize] = true;
                }
                Some(_) => return false,
            }
        }
        minors <= 1 || (knights == 0 && !(bishop_colors[0] && bishop_colors[1]))
    }

    /// The move in standard algebraic notation, such as `Nbd2`, `exd5`, `e8=Q+` or `O-O#`.
    pub fn san(&self, m: Move) -> String {
        let legal = self.legal_moves();
        let piece = self.at(m.from).expect("a move starts on a piece");
        let mut s = String::new();
        match m.kind {
            MoveKind::CastleKing => s.push_str("O-O"),
            MoveKind::CastleQueen => s.push_str("O-O-O"),
            _ if piece.kind == Kind::Pawn => {
                if m.is_capture() {
                    s.push((b'a' + file_of(m.from)) as char);
                    s.push('x');
                }
                s.push_str(&square_name(m.to));
                if let Some(k) = m.promotion {
                    s.push('=');
                    s.push_str(k.letter());
                }
            }
            _ => {
                s.push_str(piece.kind.letter());
                let rivals: Vec<Move> = legal
                    .iter()
                    .copied()
                    .filter(|o| o.to == m.to && o.from != m.from && self.at(o.from) == Some(piece))
                    .collect();
                if !rivals.is_empty() {
                    let same_file = rivals.iter().any(|o| file_of(o.from) == file_of(m.from));
                    let same_rank = rivals.iter().any(|o| rank_of(o.from) == rank_of(m.from));
                    if !same_file {
                        s.push((b'a' + file_of(m.from)) as char);
                    } else if !same_rank {
                        s.push((b'1' + rank_of(m.from)) as char);
                    } else {
                        s.push_str(&square_name(m.from));
                    }
                }
                if m.is_capture() {
                    s.push('x');
                }
                s.push_str(&square_name(m.to));
            }
        }
        let next = self.make(m);
        if next.in_check() {
            s.push(if next.legal_moves().is_empty() { '#' } else { '+' });
        }
        s
    }

    /// The legal move written `san`, with or without its `+`, `#` or `x`.
    pub fn parse_san(&self, san: &str) -> Option<Move> {
        let bare = |s: &str| s.replace(['+', '#', 'x', '!', '?'], "").replace('0', "O");
        let want = bare(san);
        self.legal_moves().into_iter().find(|&m| bare(&self.san(m)) == want)
    }

    /// The legal move in coordinates, such as `e2e4` or `e7e8q`.
    pub fn parse_uci(&self, uci: &str) -> Option<Move> {
        self.legal_moves().into_iter().find(|m| m.uci() == uci)
    }
}

/// Counts the leaf positions `depth` moves deep: the standard check that move generation is right.
pub fn perft(pos: &Position, depth: u32) -> u64 {
    if depth == 0 {
        return 1;
    }
    let mut moves = Vec::with_capacity(48);
    pos.pseudo_moves(&mut moves);
    let mut nodes = 0;
    for m in moves {
        let next = pos.make(m);
        if next.attacked(next.king(pos.side), next.side) {
            continue;
        }
        nodes += if depth == 1 { 1 } else { perft(&next, depth - 1) };
    }
    nodes
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Checkmate { winner: Color },
    Stalemate,
    Repetition,
    FiftyMoves,
    InsufficientMaterial,
}

impl Outcome {
    pub fn title(self) -> &'static str {
        match self {
            Outcome::Checkmate { .. } => "Checkmate",
            Outcome::Stalemate => "Stalemate",
            Outcome::Repetition => "Draw by repetition",
            Outcome::FiftyMoves => "Draw by the fifty-move rule",
            Outcome::InsufficientMaterial => "Draw: insufficient material",
        }
    }

    pub fn winner(self) -> Option<Color> {
        match self {
            Outcome::Checkmate { winner } => Some(winner),
            _ => None,
        }
    }
}

/// One move of a game, with what it needs to be shown and taken back.
#[derive(Clone, Debug)]
pub struct Played {
    pub before: Position,
    pub mv: Move,
    pub san: String,
    pub piece: Piece,
    pub captured: Option<Piece>,
}

/// A game: the moves so far and the position they lead to.
#[derive(Clone, Debug)]
pub struct Game {
    pub start: Position,
    pub position: Position,
    pub history: Vec<Played>,
    legal: Vec<Move>,
    /// Repetition keys of every position so far, the start included.
    keys: Vec<u64>,
    outcome: Option<Outcome>,
}

impl Default for Game {
    fn default() -> Self {
        Game::new(Position::start())
    }
}

impl Game {
    pub fn new(start: Position) -> Game {
        let mut g = Game {
            start,
            position: start,
            history: Vec::new(),
            legal: Vec::new(),
            keys: Vec::new(),
            outcome: None,
        };
        g.settle();
        g
    }

    pub fn from_fen(fen: &str) -> Result<Game, String> {
        Ok(Game::new(Position::from_fen(fen)?))
    }

    /// Works out the legal moves and whether the game is over, after the position changed.
    fn settle(&mut self) {
        let pos = &self.position;
        self.legal = pos.legal_moves();
        // A pawn that could take en passant but for a pin doesn't make the position different.
        let mut key = pos.hash;
        if let Some(ep) = pos.en_passant
            && !self.legal.iter().any(|m| m.kind == MoveKind::EnPassant)
        {
            key ^= ZOBRIST[Z_EP + file_of(ep) as usize];
        }
        self.keys.truncate(self.history.len());
        self.keys.push(key);

        self.outcome = if self.legal.is_empty() {
            Some(if pos.in_check() {
                Outcome::Checkmate { winner: pos.side.other() }
            } else {
                Outcome::Stalemate
            })
        } else if pos.insufficient_material() {
            Some(Outcome::InsufficientMaterial)
        } else if self.keys.iter().filter(|&&k| k == key).count() >= 3 {
            Some(Outcome::Repetition)
        } else if pos.halfmoves >= 100 {
            Some(Outcome::FiftyMoves)
        } else {
            None
        };
    }

    pub fn legal_moves(&self) -> &[Move] {
        &self.legal
    }

    pub fn outcome(&self) -> Option<Outcome> {
        self.outcome
    }

    pub fn is_over(&self) -> bool {
        self.outcome.is_some()
    }

    /// Repetition keys of the positions so far, oldest first, for the search to spot repeats.
    pub fn keys(&self) -> &[u64] {
        &self.keys
    }

    /// Plays `m` if it is legal and the game isn't over.
    pub fn play(&mut self, m: Move) -> bool {
        if self.is_over() || !self.legal.contains(&m) {
            return false;
        }
        let before = self.position;
        let captured = match m.kind {
            MoveKind::EnPassant => Some(Piece::new(before.side.other(), Kind::Pawn)),
            _ => before.at(m.to).filter(|_| m.is_capture()),
        };
        let played = Played {
            before,
            mv: m,
            san: before.san(m),
            piece: before.at(m.from).unwrap(),
            captured,
        };
        self.position = before.make(m);
        self.history.push(played);
        self.settle();
        true
    }

    pub fn play_san(&mut self, san: &str) -> bool {
        match self.position.parse_san(san) {
            Some(m) => self.play(m),
            None => false,
        }
    }

    /// Takes back the last move.
    pub fn undo(&mut self) -> bool {
        let Some(played) = self.history.pop() else { return false };
        self.position = played.before;
        self.settle();
        true
    }

    pub fn last_move(&self) -> Option<Move> {
        self.history.last().map(|p| p.mv)
    }

    /// The pieces each side has taken, by the colour that took them.
    pub fn captured_by(&self, color: Color) -> Vec<Piece> {
        self.history
            .iter()
            .filter(|p| p.piece.color == color)
            .filter_map(|p| p.captured)
            .collect()
    }

    /// The moves as SAN, such as `1. e4 e5 2. Nf3`.
    pub fn pgn_moves(&self) -> String {
        let mut s = String::new();
        for (i, played) in self.history.iter().enumerate() {
            let pos = &played.before;
            if pos.side == Color::White || i == 0 {
                if !s.is_empty() {
                    s.push(' ');
                }
                write!(s, "{}.", pos.fullmoves).unwrap();
                if pos.side == Color::Black {
                    s.push_str("..");
                }
            }
            s.push(' ');
            s.push_str(&played.san);
        }
        s
    }
}
