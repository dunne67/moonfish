"""Head-to-head UCI match runner with full rule adjudication.

Requires python-chess (pip install chess). Each opening is played twice with
colours reversed. Example:

    python match.py --a "luajit moonfish.lua" --b "pypy3 sunfish.py" --movetime 100 --games 100
"""
import argparse
import math
import shlex

import chess
import chess.engine

OPENINGS = [
    "e2e4 e7e5", "e2e4 c7c5", "e2e4 e7e6", "e2e4 c7c6", "d2d4 d7d5",
    "d2d4 g8f6", "c2c4 e7e5", "g1f3 d7d5", "e2e4 d7d6", "d2d4 f7f5",
    "e2e4 e7e5 g1f3 b8c6", "d2d4 d7d5 c2c4 e7e6", "e2e4 c7c5 g1f3 d7d6",
    "d2d4 g8f6 c2c4 g7g6", "e2e4 e7e5 f2f4", "c2c4 c7c5", "b2b3 e7e5",
    "e2e4 g7g6", "d2d4 g8f6 c2c4 e7e5", "e2e4 b8c6", "g2g3 d7d5",
    "e2e4 e7e5 g1f3 g8f6", "d2d4 d7d5 g1f3 g8f6", "e2e4 c7c5 b1c3",
    "e2e4 d7d5", "f2f4 d7d5", "d2d4 e7e6", "c2c4 g8f6", "e2e4 e7e5 f1c4",
    "d2d4 c7c5",
]


def play(white, black, opening, limit, max_plies):
    board = chess.Board()
    for uci in opening.split():
        board.push_uci(uci)
    while not board.is_game_over(claim_draw=True) and board.ply() < max_plies:
        engine = white if board.turn == chess.WHITE else black
        result = engine.play(board, limit)
        if result.move is None or result.move not in board.legal_moves:
            return "0-1" if board.turn == chess.WHITE else "1-0"
        board.push(result.move)
    if board.ply() >= max_plies and not board.is_game_over(claim_draw=True):
        return "1/2-1/2"
    return board.result(claim_draw=True)


def elo(score, n):
    p = min(max(score / n, 1e-3), 1 - 1e-3)
    return -400 * math.log10(1 / p - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", default="luajit moonfish.lua")
    ap.add_argument("--b", required=True, help="opponent engine command")
    ap.add_argument("--movetime", type=int, default=100, help="ms per move")
    ap.add_argument("--games", type=int, default=20)
    ap.add_argument("--max-plies", type=int, default=300)
    args = ap.parse_args()

    a = chess.engine.SimpleEngine.popen_uci(shlex.split(args.a, posix=False))
    b = chess.engine.SimpleEngine.popen_uci(shlex.split(args.b, posix=False))
    limit = chess.engine.Limit(time=args.movetime / 1000)
    wins = draws = losses = 0
    try:
        for g in range(args.games):
            opening = OPENINGS[(g // 2) % len(OPENINGS)]
            a_white = g % 2 == 0
            result = play(a, b, opening, limit, args.max_plies) if a_white else play(b, a, opening, limit, args.max_plies)
            if result == "1/2-1/2":
                draws += 1
            elif (result == "1-0") == a_white:
                wins += 1
            else:
                losses += 1
            n = g + 1
            print(f"game {n:3d}  {'A white' if a_white else 'B white'}  {result:7s}  "
                  f"+{wins} ={draws} -{losses}  elo {elo(wins + draws / 2, n):+.0f}", flush=True)
    finally:
        a.quit()
        b.quit()


if __name__ == "__main__":
    main()
