# Chess

Chess for AxiomOS, made with Hearth.

- Full rules: castling, en passant, promotion, check, checkmate, stalemate, threefold
  repetition, the fifty-move rule and insufficient material.
- Click or drag to move. Legal moves show as dots, captures as rings; the last move and a king
  in check are lit. Captured pieces, a move list in algebraic notation, and undo.
- Against the computer at four levels (Easy, Casual, Strong, Master), from either side, or two
  players at one screen.

## Playing

| Key | |
|---|---|
| Backspace, ←, Ctrl+Z | Undo (against the computer, your move and its reply) |
| N | New game |
| F | Flip the board |
| Esc | Drop the selection |

## How it's made

- `src/rules.rs`: the board, move generation (copy-make, legality by testing the king after each
  move), standard algebraic notation, FEN, and how a game ends. Zobrist hashes key repetitions.
- `src/ai.rs`: the computer. Iterative-deepening alpha-beta with a transposition table,
  quiescence search, null-move pruning, killer and history move ordering, and a tapered
  material and piece-square evaluation. Levels limit depth and nodes, not time, so it plays the
  same on any machine; the weaker ones add chance to their first move's scores.
- `src/canvas.rs`, `src/pieces.rs`, `src/ui.rs`: the game draws its whole frame on the CPU
  (signed-distance anti-aliasing for shapes, `ab_glyph` for text) into one image that the engine
  shows as a sprite. Axiom has no GPU, so this needs no more of a renderer than a textured quad.
  The pieces are drawn here as layered vector shapes.
- The font is Mona Sans (SIL Open Font License, `assets/fonts/MonaSans-OFL.txt`), embedded.

## Building

Hearth wants Rust 1.97.1, so this builds with nightly (`rust-toolchain.toml`):

```bash
hearth run --detach --cargo-arg=--ignore-rust-version
cargo test --ignore-rust-version
cargo test --release --ignore-rust-version -- --ignored   # deeper perft counts
```
