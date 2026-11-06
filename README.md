# Moonfish

A lightweight UCI chess engine for Lua 5.1, contained in a single file.

Moonfish runs on stock PUC-Lua 5.1 with no dependencies, and uses LuaJIT's `bit` and `ffi` libraries automatically when available for higher speed and responsive time control.

## Features

- **Single file, no dependencies.** Drop `moonfish.lua` anywhere and run it.
- **Allocation-free search.** Integer-packed moves, flat move stacks and make/unmake keep the garbage collector out of the hot path.
- **10×12 mailbox board.** Sentinel squares replace bounds checks; no bitwise operations are required on plain Lua 5.1.
- **Tapered PeSTO evaluation**, updated incrementally on every move.
- **Search:** iterative deepening, principal variation search, transposition table, null-move pruning, late move reductions, check extensions, mate distance pruning, and quiescence search with delta pruning.
- **Move ordering:** hash move, MVV-LVA, killer moves and history heuristic.
- **Perft-tested** move generation against standard reference positions.

## Usage

```sh
luajit moonfish.lua   # recommended
lua moonfish.lua      # plain Lua 5.1
```

To use it in a chess GUI such as Cute Chess or Arena, add a UCI engine with command `luajit` and argument `moonfish.lua`.

Supported UCI commands: `uci`, `isready`, `ucinewgame`, `position`, `go` (`depth`, `movetime`, `wtime`/`btime`/`winc`/`binc`/`movestogo`, `infinite`), `stop`, `quit`.

Debug commands: `d` (print board), `eval` (static evaluation), `perft <depth>`.

> On plain Lua 5.1 there is no portable way to poll stdin, so `stop` is only read between searches. Use a depth or time limit there, or run under LuaJIT.

## Testing

```sh
lua test_suite.lua     # perft
lua test_tactics.lua   # tactical positions
python match.py --b "pypy3 sunfish.py" --movetime 100 --games 100   # needs: pip install chess
```

`match.py` plays any two UCI engines against each other from a set of openings, with colours reversed. Opponent engines are not bundled.

## License

[MIT](LICENSE)
