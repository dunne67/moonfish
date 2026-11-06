local m = require("moonfish")

local test_cases = {
    {
        name = "Startpos",
        fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        expected = { [1] = 20, [2] = 400, [3] = 8902, [4] = 197281 }
    },
    {
        name = "Kiwipete (Tricky pins, checks, castling)",
        fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        expected = { [1] = 48, [2] = 2039, [3] = 97862 }
    },
    {
        name = "Position 3 (Endgame, en-passant pins)",
        fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        expected = { [1] = 14, [2] = 191, [3] = 2812, [4] = 43238 }
    },
    {
        name = "Position 4 (Promotions, double checks)",
        fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        expected = { [1] = 6, [2] = 264, [3] = 9467, [4] = 422333 }
    },
    {
        name = "Position 5 (Promotions, queen captures)",
        fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        expected = { [1] = 44, [2] = 1486, [3] = 62379 }
    }
}

local all_passed = true
for _, test in ipairs(test_cases) do
    print("Testing " .. test.name .. "...")
    m.load_fen(test.fen)
    for depth, exp in pairs(test.expected) do
        local count = m.perft(depth)
        if count == exp then
            print(string.format("  Depth %d: OK (%d nodes)", depth, count))
        else
            print(string.format("  Depth %d: FAILED! Got %d, Expected %d", depth, count, exp))
            all_passed = false
        end
    end
end

if all_passed then
    print("\nALL PERFT TESTS PASSED! Move generator is 100% verified.")
else
    print("\nSOME PERFT TESTS FAILED!")
end
