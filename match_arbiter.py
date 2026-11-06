import subprocess
import time
import sys

def send(proc, text):
    proc.stdin.write(text + "\n")
    proc.stdin.flush()

def read_ready(proc):
    send(proc, "isready")
    while True:
        line = proc.stdout.readline()
        if not line: break
        if "readyok" in line:
            break

def get_engine_move(proc, moves, movetime_ms, engine_name):
    cmd = "position startpos"
    if moves:
        cmd += " moves " + " ".join(moves)
    send(proc, cmd)
    send(proc, f"go movetime {movetime_ms}")

    last_info = ""
    while True:
        line = proc.stdout.readline()
        if not line:
            err = proc.stderr.read() if proc.stderr else ""
            print(f"[{engine_name} ERROR/EOF]: {err.strip()}")
            return None, last_info
        line = line.strip()
        if line.startswith("info"):
            last_info = line
        elif line.startswith("bestmove"):
            parts = line.split()
            return parts[1], last_info

def play_match(white_engine, black_engine, white_name, black_name, movetime_ms=300, max_plies=80):
    p_w = subprocess.Popen(white_engine, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    p_b = subprocess.Popen(black_engine, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    send(p_w, "uci")
    send(p_b, "uci")
    read_ready(p_w)
    read_ready(p_b)

    print("\n" + "=" * 65)
    print(f" MATCH: {white_name} (White) vs {black_name} (Black)")
    print(f" Time Control: {movetime_ms}ms per move | Max plies: {max_plies}")
    print("=" * 65)

    moves = []
    winner = "Draw"
    reason = "Max plies reached"

    for ply in range(max_plies):
        is_white = (ply % 2 == 0)
        proc = p_w if is_white else p_b
        cur_name = white_name if is_white else black_name

        t0 = time.time()
        best_m, info = get_engine_move(proc, moves, movetime_ms, cur_name)
        elapsed = time.time() - t0

        if not best_m or best_m in ("(none)", "0000"):
            winner = black_name if is_white else white_name
            reason = f"{cur_name} resigned / mated / no legal moves"
            print(f"\nGame Over at ply {ply + 1}: {reason}")
            break

        moves.append(best_m)
        m_num = (ply // 2) + 1
        side_c = "W" if is_white else "B"

        # Extract score & depth from info if available
        short_info = ""
        if "score" in info and "depth" in info:
            parts = info.split()
            try:
                d_idx = parts.index("depth")
                depth_val = parts[d_idx + 1]
                sc_idx = parts.index("score")
                sc_type = parts[sc_idx + 1]
                sc_val = parts[sc_idx + 2]
                short_info = f"d:{depth_val} {sc_type}:{sc_val}"
                if "nps" in parts:
                    nps_idx = parts.index("nps")
                    short_info += f" nps:{parts[nps_idx + 1]}"
            except Exception:
                short_info = info[:40]

        print(f"Move {m_num:2d}{side_c}: {cur_name:<10} -> {best_m:<5} ({elapsed:.2f}s) {short_info}")

        # Simple repetition detection
        if len(moves) >= 8 and moves[-1] == moves[-5] == moves[-9] and moves[-2] == moves[-6] == moves[-10]:
            winner = "Draw"
            reason = "3-fold repetition"
            print(f"\nDraw declared by 3-fold repetition at ply {ply + 1}!")
            break

    send(p_w, "quit")
    send(p_b, "quit")
    p_w.wait()
    p_b.wait()

    print("\n" + "-" * 65)
    print(f"Result: {winner} ({reason})")
    print(f"Total plies: {len(moves)}")
    print("Move list: " + " ".join(moves))
    print("-" * 65)
    return winner

if __name__ == "__main__":
    ms = int(sys.argv[1]) if len(sys.argv) > 1 else 300

    print(">>> GAME 1: Moonfish (White) vs Sunfish (Black) <<<")
    play_match(["luajit", "moonfish.lua"], ["python", "sunfish.py"], "Moonfish", "Sunfish", movetime_ms=ms, max_plies=70)

    print("\n>>> GAME 2: Sunfish (White) vs Moonfish (Black) <<<")
    play_match(["python", "sunfish.py"], ["luajit", "moonfish.lua"], "Sunfish", "Moonfish", movetime_ms=ms, max_plies=70)
