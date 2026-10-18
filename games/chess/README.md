# Chess

Chess for AxiomOS, made with Hearth.

- Full rules: castling, en passant, promotion, check, checkmate, stalemate, threefold
  repetition, the fifty-move rule and insufficient material.
- Click or drag to move. Legal moves show as dots, captures as rings; the last move and a king
  in check are lit. Captured pieces, a move list in algebraic notation, and undo.
- Against the computer at four levels (Easy, Casual, Strong, Master), from either side, or two
  players at one screen.
- Light and dark appearances: the sun or moon button by the title, or D.

## Playing

| Key | |
|---|---|
| Backspace, ←, Ctrl+Z | Undo (against the computer, your move and its reply) |
| N | New game |
| F | Flip the board |
| D | Switch between light and dark |
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
  It builds with Hearth's CPU renderer (`2d_soft`), with no wgpu, on the desktop as on Axiom.
  The pieces are drawn here as layered vector shapes.
- The font is Mona Sans (SIL Open Font License, `assets/fonts/MonaSans-OFL.txt`), embedded.

Arguments: `--fen <FEN>` starts from a position, `--two` with two players, `--dark` in the dark
appearance (on Axiom, the system's appearance is the default), and `--no-threads` makes the computer think between frames, as on a system without
threads.

## Building

Hearth wants Rust 1.97.1, so this builds with nightly (`rust-toolchain.toml`):

```bash
hearth run --detach --cargo-arg=--ignore-rust-version
cargo test --ignore-rust-version
cargo test --release --ignore-rust-version -- --ignored   # deeper perft counts
```

### For Axiom

The same code runs on Axiom through Hearth's `hearth_axiom`, which `2d_soft` brings in for
Axiom's target (`x86_64-axiom.json`, from Axiom's `sdk/rust`). Build it with `std` from source,
without the remote protocol (Axiom has no sockets for it yet), and in the `axiom` profile, which
keeps the program under the 16 MiB an .AXE may be:

```bash
cargo +nightly build --profile axiom --ignore-rust-version --no-default-features -Zbuild-std=std,panic_abort -Zbuild-std-features=compiler-builtins-mem -Zjson-target-spec --target x86_64-axiom.json
python <axiom>/tools/mkaxe.py target/x86_64-axiom/axiom/chess CHESS.AXE
```

Put `CHESS.AXE` in `EFI/AXIOM` on the boot stick and type `chess` in a shell. The game needs no
files beside it: the font is embedded. On Axiom it starts in the system's appearance, opens a
window that fits the screen, and the computer thinks between frames, as there are no threads.
