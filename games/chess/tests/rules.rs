//! The rules beyond how pieces move: castling, en passant, promotion, notation, and the ways a
//! game ends.

use chess::ai::{self, LEVELS};
use chess::rules::{Color, Game, Kind, MoveKind, Outcome, Piece, Position};

fn game(moves: &str) -> Game {
    let mut g = Game::default();
    for san in moves.split_whitespace() {
        assert!(g.play_san(san), "{san} should be legal after {}", g.pgn_moves());
    }
    g
}

fn fen_game(fen: &str, moves: &str) -> Game {
    let mut g = Game::from_fen(fen).unwrap();
    for san in moves.split_whitespace() {
        assert!(g.play_san(san), "{san} should be legal in {}", g.position.fen());
    }
    g
}

fn sans(g: &Game) -> Vec<String> {
    let mut v: Vec<String> = g.legal_moves().iter().map(|&m| g.position.san(m)).collect();
    v.sort();
    v
}

#[test]
fn castles_both_ways() {
    let g = fen_game("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "O-O O-O-O");
    assert_eq!(g.position.fen(), "2kr3r/8/8/8/8/8/8/R4RK1 w - - 2 2");
}

#[test]
fn no_castling_out_of_through_or_into_check() {
    // The rooks on f8 and c8 cover squares the king crosses or lands on.
    let g = Game::from_fen("2r1kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1").unwrap();
    assert!(!sans(&g).iter().any(|s| s.starts_with("O-O")));
    // In check: no castling at all.
    let g = Game::from_fen("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1").unwrap();
    assert!(!sans(&g).iter().any(|s| s.starts_with("O-O")));
    // An attacked b1 doesn't stop the long castle: only the king's squares count.
    let g = Game::from_fen("1r2k3/8/8/8/8/8/8/R3K3 w Q - 0 1").unwrap();
    assert!(sans(&g).contains(&"O-O-O".to_string()));
}

#[test]
fn castling_rights_go_with_the_king_and_rooks() {
    let g = fen_game("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "Rb1 Rg8");
    assert_eq!(g.position.fen(), "r3k1r1/8/8/8/8/8/8/1R2K2R w Kq - 2 2");
    // Taking a rook at home takes its castling with it.
    let g = fen_game("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "Rxa8+");
    assert_eq!(g.position.castling, chess::rules::WHITE_SHORT | chess::rules::BLACK_SHORT);
    let g = fen_game("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "Ke2");
    assert_eq!(g.position.fen(), "r3k2r/8/8/8/8/8/4K3/R6R b kq - 1 1");
}

#[test]
fn en_passant_only_at_once() {
    let mut g = game("e4 a6 e5 d5");
    assert!(g.legal_moves().iter().any(|m| m.kind == MoveKind::EnPassant));
    assert!(g.play_san("exd6"));
    assert_eq!(g.position.at(chess::rules::parse_square("d5").unwrap()), None);
    assert_eq!(g.history.last().unwrap().captured, Some(Piece::new(Color::Black, Kind::Pawn)));

    // Waiting a move loses the chance.
    let g = game("e4 a6 e5 d5 a3 a5");
    assert!(!g.legal_moves().iter().any(|m| m.kind == MoveKind::EnPassant));
}

#[test]
fn en_passant_that_exposes_the_king_is_illegal() {
    // Taking d6 would clear the fifth rank between the rook and the king.
    let g = Game::from_fen("7k/8/8/K2pP2r/8/8/8/8 w - d6 0 1").unwrap();
    assert!(!g.legal_moves().iter().any(|m| m.kind == MoveKind::EnPassant));
}

#[test]
fn promotes_to_any_piece() {
    let g = Game::from_fen("k7/4P3/8/8/8/8/8/4K3 w - - 0 1").unwrap();
    let promotions: Vec<String> = sans(&g).into_iter().filter(|s| s.contains('=')).collect();
    assert_eq!(promotions, ["e8=B", "e8=N", "e8=Q+", "e8=R+"]);
    let g = fen_game("k7/4P3/8/8/8/8/8/4K3 w - - 0 1", "e8=N");
    assert_eq!(g.position.at(60), Some(Piece::new(Color::White, Kind::Knight)));
}

#[test]
fn notation_tells_twins_apart() {
    let g = Game::from_fen("4k3/8/8/8/R7/8/8/RN2KN2 w - - 0 1").unwrap();
    let all = sans(&g);
    for want in ["Nbd2", "Nfd2", "R1a2", "R4a2", "R1a3", "Rb4"] {
        assert!(all.contains(&want.to_string()), "{want} in {all:?}");
    }
    // Three queens that share files and ranks need the whole square.
    let g = Game::from_fen("4k3/8/8/8/8/Q1Q5/8/Q3K3 w - - 0 1").unwrap();
    assert!(sans(&g).contains(&"Qa3b2".to_string()));
}

#[test]
fn fools_mate() {
    let g = game("f3 e5 g4 Qh4#");
    assert_eq!(g.outcome(), Some(Outcome::Checkmate { winner: Color::Black }));
    assert_eq!(g.history.last().unwrap().san, "Qh4#");
    assert_eq!(g.pgn_moves(), "1. f3 e5 2. g4 Qh4#");
}

#[test]
fn stalemate() {
    let g = Game::from_fen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").unwrap();
    assert_eq!(g.outcome(), Some(Outcome::Stalemate));
}

#[test]
fn threefold_repetition() {
    let mut g = game("Nf3 Nf6 Ng1 Ng8 Nf3 Nf6 Ng1");
    assert_eq!(g.outcome(), None);
    g.play_san("Ng8");
    assert_eq!(g.outcome(), Some(Outcome::Repetition));
    // Undo brings the game back.
    g.undo();
    assert_eq!(g.outcome(), None);
}

#[test]
fn repetition_needs_the_same_rights() {
    // The kings walk out and back: the same squares, but castling is gone, so the first
    // position doesn't count again.
    let g = game("e4 e5 Ke2 Ke7 Ke1 Ke8 Ke2 Ke7 Ke1 Ke8");
    assert_eq!(g.outcome(), None);
    let mut g = g;
    g.play_san("Ke2");
    g.play_san("Ke7");
    assert_eq!(g.outcome(), Some(Outcome::Repetition));
}

#[test]
fn fifty_move_rule() {
    let mut g = Game::from_fen("4k3/8/8/8/8/8/8/R3K3 w - - 99 80").unwrap();
    assert_eq!(g.outcome(), None);
    g.play_san("Ra2");
    assert_eq!(g.outcome(), Some(Outcome::FiftyMoves));
    // A capture or pawn move starts the count again.
    let g = fen_game("4k3/8/8/8/8/8/P7/R3K3 w - - 99 80", "a3");
    assert_eq!(g.outcome(), None);
}

#[test]
fn mate_beats_the_fifty_move_rule() {
    let g = fen_game("k7/8/1K6/8/8/8/8/7R w - - 99 80", "Rh8#");
    assert_eq!(g.outcome(), Some(Outcome::Checkmate { winner: Color::White }));
}

#[test]
fn insufficient_material() {
    for fen in ["4k3/8/8/8/8/8/8/4K3 w - - 0 1", "4k3/8/8/8/8/8/8/3NK3 w - - 0 1", "2b1k3/8/8/8/8/8/8/3BK3 w - - 0 1"] {
        assert_eq!(Game::from_fen(fen).unwrap().outcome(), Some(Outcome::InsufficientMaterial), "{fen}");
    }
    for fen in ["3bk3/8/8/8/8/8/8/3BK3 w - - 0 1", "4k3/8/8/8/8/8/8/2NNK3 w - - 0 1", "4k3/8/8/8/8/8/P7/4K3 w - - 0 1"] {
        assert_eq!(Game::from_fen(fen).unwrap().outcome(), None, "{fen}");
    }
}

#[test]
fn undo_restores_everything() {
    let mut g = game("e4 d5 exd5 Qxd5 Nc3");
    assert_eq!(g.captured_by(Color::White), [Piece::new(Color::Black, Kind::Pawn)]);
    assert_eq!(g.captured_by(Color::Black), [Piece::new(Color::White, Kind::Pawn)]);
    while g.undo() {}
    assert_eq!(g.position, Position::start());
    assert_eq!(g.legal_moves().len(), 20);
    assert!(!g.undo());
}

#[test]
fn nothing_plays_after_the_end() {
    let mut g = game("f3 e5 g4 Qh4#");
    assert!(!g.play_san("a3"));
}

#[test]
fn computer_takes_a_free_queen_and_mates_in_one() {
    let pos = Position::from_fen("4k3/8/8/3q4/8/8/8/3RK3 w - - 0 1").unwrap();
    let found = ai::choose(&pos, &[], LEVELS[2], 1).unwrap();
    assert_eq!(pos.san(found.mv), "Rxd5");

    let pos = Position::from_fen("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1").unwrap();
    for level in LEVELS[1..].iter() {
        let found = ai::choose(&pos, &[], *level, 7).unwrap();
        assert_eq!(pos.san(found.mv), "Ra8#", "{}", level.name);
    }
}

#[test]
fn computer_finds_a_mate_in_two() {
    // 1. Rb7 Kg8 2. Ra8#, or the same with the rooks swapped.
    let pos = Position::from_fen("7k/8/8/8/8/8/R7/1R4K1 w - - 0 1").unwrap();
    let found = ai::choose(&pos, &[], LEVELS[3], 1).unwrap();
    assert_eq!(ai::mate_in(found.score), Some(2), "{}", pos.san(found.mv));
}

#[test]
fn computer_always_has_a_legal_move() {
    let mut g = Game::default();
    let mut seed = 1;
    while !g.is_over() && g.history.len() < 60 {
        let keys = g.keys();
        let found = ai::choose(&g.position, &keys[..keys.len() - 1], LEVELS[g.history.len() % 2], seed).unwrap();
        assert!(g.play(found.mv));
        seed += 1;
    }
}
