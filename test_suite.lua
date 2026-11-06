-- Perft validation: compares move-generator node counts with published values.
-- Usage: lua test_suite.lua   (or luajit test_suite.lua)
package.path = "./?.lua;" .. package.path
local m = require("moonfish")

local cases = {
    { "Startpos", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
      { 20, 400, 8902, 197281 } },
    { "Kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
      { 48, 2039, 97862 } },
    { "Position 3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
      { 14, 191, 2812, 43238 } },
    { "Position 4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
      { 6, 264, 9467, 422333 } },
    { "Position 5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
      { 44, 1486, 62379 } },
}

local failures = 0
for _, c in ipairs(cases) do
    local name, fen, expected = c[1], c[2], c[3]
    m.load_fen(fen)
    for depth = 1, #expected do
        local got = m.perft(depth)
        local ok = got == expected[depth]
        if not ok then failures = failures + 1 end
        print(string.format("%-11s depth %d  %9d  %s", name, depth, got,
            ok and "ok" or ("FAIL (expected " .. expected[depth] .. ")")))
    end
end

if failures == 0 then
    print("\nAll perft tests passed.")
else
    print(string.format("\n%d perft test(s) failed.", failures))
    os.exit(1)
end
