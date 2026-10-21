//! Move generation, checked against the published perft counts of the standard test positions
//! (chessprogramming.org/Perft_Results). The deeper counts are ignored by default; run them with
//! `cargo test --release -- --ignored`.

use chess::rules::{Position, START_FEN, perft};

const KIWIPETE: &str = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
const POSITION_3: &str = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
const POSITION_4: &str = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
const POSITION_4_MIRRORED: &str = "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1";
const POSITION_5: &str = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
const POSITION_6: &str = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";

fn check(fen: &str, counts: &[u64]) {
    let pos = Position::from_fen(fen).unwrap();
    for (i, &want) in counts.iter().enumerate() {
        let depth = i as u32 + 1;
        assert_eq!(perft(&pos, depth), want, "perft({depth}) of {fen}");
    }
}

#[test]
fn start() {
    check(START_FEN, &[20, 400, 8_902, 197_281]);
}

#[test]
fn kiwipete() {
    check(KIWIPETE, &[48, 2_039, 97_862]);
}

#[test]
fn position_3() {
    check(POSITION_3, &[14, 191, 2_812, 43_238, 674_624]);
}

#[test]
fn position_4() {
    check(POSITION_4, &[6, 264, 9_467, 422_333]);
    check(POSITION_4_MIRRORED, &[6, 264, 9_467, 422_333]);
}

#[test]
fn position_5() {
    check(POSITION_5, &[44, 1_486, 62_379]);
}

#[test]
fn position_6() {
    check(POSITION_6, &[46, 2_079, 89_890]);
}

#[test]
#[ignore = "slow outside release builds"]
fn deep() {
    check(START_FEN, &[20, 400, 8_902, 197_281, 4_865_609]);
    check(KIWIPETE, &[48, 2_039, 97_862, 4_085_603]);
    check(POSITION_3, &[14, 191, 2_812, 43_238, 674_624, 11_030_083]);
    check(POSITION_5, &[44, 1_486, 62_379, 2_103_487]);
    check(POSITION_6, &[46, 2_079, 89_890, 3_894_594]);
}

#[test]
fn fen_round_trip() {
    for fen in [START_FEN, KIWIPETE, POSITION_3, POSITION_4, POSITION_5, POSITION_6] {
        assert_eq!(Position::from_fen(fen).unwrap().fen(), fen);
    }
}
