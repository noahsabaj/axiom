//! How long each level takes to choose a move in a busy middlegame. Run with
//! `cargo test --release -- --ignored --nocapture speed`.

use chess::ai::{LEVELS, Search};
use chess::rules::Position;

#[test]
#[ignore = "a measurement, not a check"]
fn speed() {
    let pos = Position::from_fen("r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R2QKB1R w KQ - 0 8").unwrap();
    for level in LEVELS {
        let start = std::time::Instant::now();
        let mut search = Search::new(&pos, &[], level, 1).sliced(30_000);
        // The longest step is the longest the window can stall where the game has one thread.
        let mut longest = std::time::Duration::ZERO;
        loop {
            let step = std::time::Instant::now();
            let done = search.step();
            longest = longest.max(step.elapsed());
            if done {
                break;
            }
        }
        let found = search.result().unwrap();
        println!(
            "{:7} {:6} depth {:2} nodes {:8} score {:5} in {:?}, longest step {:?}",
            level.name,
            pos.san(found.mv),
            found.depth,
            found.nodes,
            found.score,
            start.elapsed(),
            longest
        );
    }
}
