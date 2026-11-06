local m = require("moonfish")

local puzzles = {
    {
        name = "Mate in 1 (Scholar's Mate threat)",
        fen = "r1bqkb1r/pppp1ppp/2n5/4p3/2B1n3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1",
        expected_move = "f3f7",
        depth = 3
    },
    {
        name = "Back Rank Mate in 1",
        fen = "6k1/5ppp/8/8/8/8/1Q4PP/6K1 w - - 0 1",
        expected_move = "b2b8",
        depth = 3
    },
    {
        name = "Mate in 2 (Qxf7+ Rxf7 Re8#)",
        fen = "r1b2rk1/ppp2ppp/8/8/2B5/5Q2/PPP2PPP/4R1K1 w - - 0 1",
        expected_move = "f3f7",
        depth = 4
    },
    {
        name = "Hanging Queen Capture",
        fen = "rnb1kbnr/pppp1ppp/8/4q3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",
        expected_move = "d1e2", -- or defending / whatever
        depth = 4
    }
}

for _, p in ipairs(puzzles) do
    print("\n--- Puzzle: " .. p.name .. " ---")
    m.load_fen(p.fen)
    local best = m.search_position(p.depth, 1000)
    print("Expected: " .. p.expected_move)
end
