-- Tactical regression tests: each position has a single best move.
-- Usage: lua test_tactics.lua   (or luajit test_tactics.lua)
package.path = "./?.lua;" .. package.path
local m = require("moonfish")

local puzzles = {
    { "Mate in 1: Qxf7#",          "r1bqkb1r/pppp1ppp/2n5/4p3/2B1n3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1", "f3f7", 4 },
    { "Mate in 1: back rank",      "6k1/5ppp/8/8/8/8/1Q4PP/6K1 w - - 0 1",                              "b2b8", 4 },
    { "Mate in 2: Qxf7+ Rxf7 Re8#","r1b2rk1/ppp2ppp/8/8/2B5/5Q2/PPP2PPP/4R1K1 w - - 0 1",               "f3f7", 5 },
    { "Win the hanging queen",     "rnb1kbnr/pppp1ppp/8/4q3/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 1",      "d4e5", 4 },
    { "Knight fork",               "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",                                  "b5c7", 4 },
    { "Promote the pawn",          "8/4P3/8/8/6K1/8/k6r/8 w - - 0 1",                                   "e7e8q", 4 },
}

local failures = 0
for _, p in ipairs(puzzles) do
    local name, fen, expected, depth = p[1], p[2], p[3], p[4]
    m.load_fen(fen)
    m.clear_tt()
    local best = m.move_to_uci(m.search_position(depth, nil, nil, true, true))
    local ok = best == expected
    if not ok then failures = failures + 1 end
    print(string.format("%-28s %-6s %s", name, best, ok and "ok" or ("FAIL (expected " .. expected .. ")")))
end

if failures == 0 then
    print("\nAll tactical tests passed.")
else
    print(string.format("\n%d tactical test(s) failed.", failures))
    os.exit(1)
end
