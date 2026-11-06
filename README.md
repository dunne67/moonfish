# Moonfish

> A lightweight, high-performance chess engine in a single Lua 5.1 file.

Moonfish is a self-contained, dependency-free chess engine designed for maximum efficiency in Lua 5.1 and LuaJIT environments. Engineered with zero-allocation data structures and state-of-the-art alpha-beta search heuristics, it delivers grandmaster-level tactical speed while remaining under 900 lines of clean, readable code.

---

## Highlights

- **Single-File Architecture**: Everything lives in `moonfish.lua` with zero external dependencies.
- **Pure Lua 5.1 & LuaJIT Compatible**: Runs natively on standard PUC-Lua 5.1 (`lua.exe`) and unlocks over **1,000,000 nodes/sec** under LuaJIT.
- **Zero-Allocation Search**: Move generation and search loop run without allocating heap tables, completely eliminating Lua garbage collection overhead.
- **UCI Protocol Compliant**: Plug-and-play with Cutechess, Arena, Banksia GUI, and Lichess-bot.
- **100% Perft Verified**: Formally verified against standard Perft suites (Startpos, Kiwipete, Positions 3–5).

---

## Engine Architecture

### Board Representation
- **10×12 Mailbox (120 squares)**: Folded boundary and collision checks via array sentinels. Requires zero bitwise operations, maximizing speed across all Lua runtimes.
- **Bit-Packed Moves**: Moves are encoded into compact integers containing source, destination, promotion piece, and special move flags.
- **In-Place Undo Stack**: Board state changes are tracked through pre-allocated arrays, enabling immediate make/unmake operations without table copies.

### Evaluation
- **Tapered PeSTO Piece-Square Tables**: Seamless interpolation between Middlegame (MG) and Endgame (EG) tables based on non-pawn material phase.
- **Incremental $O(1)$ Updates**: Material and positional scores update incrementally during moves. Leaf node evaluation requires zero board scanning loops.

### Search & Heuristics
- **Negamax $\alpha$-$\beta$** with Iterative Deepening
- **Transposition Table**: 262,144 entries using hybrid Zobrist hashing (LuaJIT native bitwise operations with a precomputed byte-table fallback for vanilla Lua 5.1).
- **Move Ordering**:
  1. Transposition Table best move
  2. MVV-LVA (Most Valuable Victim – Least Valuable Attacker)
  3. Killer Moves (2 per ply)
  4. History Heuristic for quiet moves
  5. In-place selection sort (immediate break on beta cutoffs)
- **Selectivity & Pruning**:
  - Quiescence Search (QS) with Delta Pruning
  - Null Move Pruning (NMP, $R=2/3$) with zugzwang safety check
  - Late Move Reductions (LMR)
  - Check Extensions (+1 ply on check)

---

## Quickstart

### Interactive / UCI Mode

Launch Moonfish directly using LuaJIT or standard Lua:

```bash
luajit moonfish.lua
# or
lua moonfish.lua
```

In standard UCI GUIs (e.g. Cutechess), register Moonfish by pointing the engine command to `luajit` (or `lua`) with argument `moonfish.lua`.

### Built-in Commands

Moonfish supports standard UCI commands alongside interactive debugging tools:

```
uci                                    Handshake and engine identifier
isready                                Verifies readiness
position startpos moves e2e4 e7e5 ...  Sets up board position
go depth 6                             Searches to a fixed depth
go movetime 1000                       Searches for 1 second
perft 4                                Runs Perft move validation to depth 4
d                                      Renders ASCII board and game state
eval                                   Displays current static evaluation
```

---

## Testing & Benchmarks

Run the Perft validation suite:
```bash
luajit test_suite.lua
# or
lua test_suite.lua
```

Run tactical puzzle benchmarks:
```bash
luajit test_tactics.lua
```

Run an automated match against Sunfish:
```bash
python match_arbiter.py 250
```

---

## License

Moonfish is licensed under the [MIT License](LICENSE). Free for personal, academic, and commercial use.
