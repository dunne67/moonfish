-- ============================================================================
-- Moonfish: A High-Performance Single-File Chess Engine for Lua 5.1 & LuaJIT
-- ============================================================================

local Moonfish = {}

-- Fast local references
local floor = math.floor
local abs = math.abs
local min = math.min
local max = math.max
local str_byte = string.byte
local str_char = string.char
local str_sub = string.sub
local str_find = string.find
local str_format = string.format
-- Wall-clock timer. os.clock() measures CPU time on POSIX systems, so under
-- LuaJIT we use the OS monotonic clock via FFI; plain Lua 5.1 falls back to os.clock.
local clock = os.clock
do
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi then
        local ok = pcall(function()
            if ffi.os == "Windows" then
                ffi.cdef("int QueryPerformanceCounter(int64_t *c); int QueryPerformanceFrequency(int64_t *f);")
                local c, f = ffi.new("int64_t[1]"), ffi.new("int64_t[1]")
                ffi.C.QueryPerformanceFrequency(f)
                local freq = tonumber(f[0])
                clock = function() ffi.C.QueryPerformanceCounter(c); return tonumber(c[0]) / freq end
            else
                ffi.cdef("typedef struct { long tv_sec; long tv_nsec; } mf_timespec; int clock_gettime(int id, mf_timespec *ts);")
                local ts = ffi.new("mf_timespec")
                clock = function() ffi.C.clock_gettime(1, ts); return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9 end
            end
            clock()
        end)
        if not ok then clock = os.clock end
    end
end

-- ----------------------------------------------------------------------------
-- Bitwise XOR Support (LuaJIT native bitlib with PUC Lua 5.1 byte-table fallback)
-- ----------------------------------------------------------------------------
local bxor
local has_bit, bit = pcall(require, "bit")
if has_bit and bit and bit.bxor then
    bxor = bit.bxor
else
    local xor_byte = {}
    for i = 0, 255 do
        for j = 0, 255 do
            local a, b, res, bitval = i, j, 0, 1
            for k = 1, 8 do
                if (a % 2) ~= (b % 2) then res = res + bitval end
                a = floor(a / 2)
                b = floor(b / 2)
                bitval = bitval * 2
            end
            xor_byte[i * 256 + j] = res
        end
    end

    bxor = function(a, b)
        local a0, b0 = a % 256, b % 256
        a = (a - a0) / 256; b = (b - b0) / 256
        local a1, b1 = a % 256, b % 256
        a = (a - a1) / 256; b = (b - b1) / 256
        local a2, b2 = a % 256, b % 256
        a = (a - a2) / 256; b = (b - b2) / 256
        local a3, b3 = a % 256, b % 256
        return xor_byte[a0 * 256 + b0] +
               xor_byte[a1 * 256 + b1] * 256 +
               xor_byte[a2 * 256 + b2] * 65536 +
               xor_byte[a3 * 256 + b3] * 16777216
    end
end

-- ----------------------------------------------------------------------------
-- Constants & Board Layout (10x12 Mailbox, 120 squares)
-- ----------------------------------------------------------------------------
local WHITE = 0
local BLACK = 1

local EMPTY    = 0
local W_PAWN   = 1
local W_KNIGHT = 2
local W_BISHOP = 3
local W_ROOK   = 4
local W_QUEEN  = 5
local W_KING   = 6
local B_PAWN   = 7
local B_KNIGHT = 8
local B_BISHOP = 9
local B_ROOK   = 10
local B_QUEEN  = 11
local B_KING   = 12
local OFFBOARD = 99

local PIECE_COLOR = {
    [0] = -1,
    [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0,
    [7] = 1, [8] = 1, [9] = 1, [10] = 1, [11] = 1, [12] = 1,
    [99] = -1
}

local PIECE_TYPE = {
    [0] = 0,
    [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6,
    [7] = 1, [8] = 2, [9] = 3, [10] = 4, [11] = 5, [12] = 6,
    [99] = 0
}

local CHAR_TO_PIECE = {
    ["P"] = W_PAWN,   ["N"] = W_KNIGHT, ["B"] = W_BISHOP,
    ["R"] = W_ROOK,   ["Q"] = W_QUEEN,  ["K"] = W_KING,
    ["p"] = B_PAWN,   ["n"] = B_KNIGHT, ["b"] = B_BISHOP,
    ["r"] = B_ROOK,   ["q"] = B_QUEEN,  ["k"] = B_KING
}

local PIECE_TO_CHAR = {
    [0] = ".",
    [1] = "P", [2] = "N", [3] = "B", [4] = "R", [5] = "Q", [6] = "K",
    [7] = "p", [8] = "n", [9] = "b", [10] = "r", [11] = "q", [12] = "k",
    [99] = " "
}

-- Castling Rights Bitflags
local CASTLE_WK = 1
local CASTLE_WQ = 2
local CASTLE_BK = 4
local CASTLE_BQ = 8

local CASTLE_RIGHTS_MASK = {}
for sq = 1, 120 do CASTLE_RIGHTS_MASK[sq] = 15 end
CASTLE_RIGHTS_MASK[21] = 15 - CASTLE_WQ
CASTLE_RIGHTS_MASK[25] = 15 - CASTLE_WK - CASTLE_WQ
CASTLE_RIGHTS_MASK[28] = 15 - CASTLE_WK
CASTLE_RIGHTS_MASK[91] = 15 - CASTLE_BQ
CASTLE_RIGHTS_MASK[95] = 15 - CASTLE_BK - CASTLE_BQ
CASTLE_RIGHTS_MASK[98] = 15 - CASTLE_BK

local CASTLE_AND = {}
for r = 0, 15 do
    CASTLE_AND[r] = {}
    for m = 0, 15 do
        local res = 0
        local bitval = 1
        local tr, tm = r, m
        for k = 1, 4 do
            if (tr % 2 == 1) and (tm % 2 == 1) then res = res + bitval end
            tr = floor(tr / 2)
            tm = floor(tm / 2)
            bitval = bitval * 2
        end
        CASTLE_AND[r][m] = res
    end
end

-- Square Coordinate Helpers
local SQ_TO_COORD = {}
local COORD_TO_SQ = {}
for r = 1, 8 do
    for f = 1, 8 do
        local sq = (r + 1) * 10 + f
        local coord = str_char(96 + f) .. str_char(48 + r)
        SQ_TO_COORD[sq] = coord
        COORD_TO_SQ[coord] = sq
    end
end

-- Move Flags
local FLAG_NORMAL = 0
local FLAG_EP     = 1
local FLAG_CASTLE = 2
local FLAG_DOUBLE = 3

local function pack_move(from_sq, to_sq, promo, flag)
    return from_sq + to_sq * 128 + (promo or 0) * 16384 + (flag or 0) * 262144
end

local function move_from(m)  return m % 128 end
local function move_to(m)    return floor(m / 128) % 128 end
local function move_promo(m) return floor(m / 16384) % 16 end
local function move_flag(m)  return floor(m / 262144) end

local PROMO_CHARS = { [W_KNIGHT] = "n", [W_BISHOP] = "b", [W_ROOK] = "r", [W_QUEEN] = "q" }
local function move_to_uci(m)
    if not m or m == 0 then return "(none)" end
    local from_sq = move_from(m)
    local to_sq = move_to(m)
    local promo = move_promo(m)
    local str = (SQ_TO_COORD[from_sq] or "??") .. (SQ_TO_COORD[to_sq] or "??")
    if promo > 0 then
        str = str .. (PROMO_CHARS[promo] or "q")
    end
    return str
end

-- Direction offsets for 10x12 board
local NORTH = 10
local SOUTH = -10
local EAST  = 1
local WEST  = -1

local KNIGHT_DELTAS = { 21, 19, 12, 8, -8, -12, -19, -21 }
local BISHOP_DELTAS = { 11, 9, -9, -11 }
local ROOK_DELTAS   = { 10, -10, 1, -1 }
local KING_DELTAS   = { 10, -10, 1, -1, 11, 9, -9, -11 }

-- ----------------------------------------------------------------------------
-- Zobrist Hashing
-- ----------------------------------------------------------------------------
local ZOBRIST_PIECE = {}
for p = 1, 12 do
    ZOBRIST_PIECE[p] = {}
    for sq = 1, 120 do
        ZOBRIST_PIECE[p][sq] = 0
    end
end
local ZOBRIST_CASTLING = {}
local ZOBRIST_EP = {}
local ZOBRIST_SIDE = 0

do
    local seed = 1070372
    local function rand32()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed
    end

    for p = 1, 12 do
        for sq = 1, 120 do
            if SQ_TO_COORD[sq] then
                ZOBRIST_PIECE[p][sq] = rand32()
            end
        end
    end
    for c = 0, 15 do
        ZOBRIST_CASTLING[c] = rand32()
    end
    for f = 0, 8 do
        ZOBRIST_EP[f] = rand32()
    end
    ZOBRIST_SIDE = rand32()
end

-- ----------------------------------------------------------------------------
-- PeSTO Evaluation Piece-Square Tables (Tapered MG & EG)
-- ----------------------------------------------------------------------------
local MG_VALUE = { [1] = 82, [2] = 337, [3] = 365, [4] = 477, [5] = 1025, [6] = 0 }
local EG_VALUE = { [1] = 94, [2] = 281, [3] = 297, [4] = 512, [5] = 936,  [6] = 0 }

local GAME_PHASE_INC = { [1] = 0, [2] = 1, [3] = 1, [4] = 2, [5] = 4, [6] = 0 }

local PESTO_MG = {
    [1] = {
          0,   0,   0,   0,   0,   0,   0,   0,
         98, 134,  61,  95,  68, 126,  34, -11,
         -6,   7,  26,  31,  65,  56,  25, -20,
        -14,  13,   6,  21,  23,  12,  17, -23,
        -27,  -2,  -5,  12,  17,   6,  10, -25,
        -26,  -4,  -4, -10,   3,   3,  33, -12,
        -35,  -1, -20, -23, -15,  24,  38, -22,
          0,   0,   0,   0,   0,   0,   0,   0
    },
    [2] = {
       -167, -89, -34, -49,  61, -97, -15, -107,
        -73, -41,  72,  36,  23,  62,   7,  -17,
        -47,  60,  37,  65,  84, 129,  73,   44,
         -9,  17,  19,  53,  37,  69,  18,   22,
        -13,   4,  16,  13,  28,  19,  21,   -8,
        -23,  -9,  12,  10,  19,  17,  25,  -16,
        -29, -53, -12,  -3,  -1,  18, -14,  -19,
       -105, -21, -58, -33, -17, -28, -19,  -23
    },
    [3] = {
        -29,   4, -82, -37, -25, -42,   7,  -8,
        -26,  16, -18, -13,  30,  59,  18, -47,
        -16,  37,  43,  40,  35,  50,  37,  -2,
         -4,   5,  19,  50,  37,  37,   7,  -2,
         -6,  13,  13,  26,  34,  12,  10,   4,
          0,  15,  15,  15,  14,  27,  18,  10,
          4,  15,  16,   0,   7,  21,  33,   1,
        -33,  -3, -14, -21, -13, -12, -39, -21
    },
    [4] = {
         32,  42,  32,  51,  63,   9,  31,  43,
         27,  32,  58,  62,  80,  67,  26,  44,
         -5,  19,  26,  36,  17,  45,  61,  16,
        -24, -11,   7,  26,  24,  35,  -8, -20,
        -36, -26, -12,  -1,   9,  -7,   6, -23,
        -45, -25, -16, -17,   3,   0,  -5, -33,
        -44, -16, -20,  -9,  -1,  11,  -6, -71,
        -19, -13,   1,  17,  16,   7, -37, -26
    },
    [5] = {
        -28,   0,  29,  12,  59,  44,  43,  45,
        -24, -39,  -5,   1, -16,  57,  28,  54,
        -13, -17,   7,   8,  29,  56,  47,  57,
        -27, -27, -16, -16,  -1,  17,  -2,   1,
         -9, -26,  -9, -10,  -2,  -4,   3,  -3,
        -14,   2, -11,  -2,  -5,   2,  14,   5,
        -35,  -8,  11,   2,   8,  15,  -3,   1,
         -1, -18,  -9,  10, -15, -25, -31, -50
    },
    [6] = {
        -65,  23,  16, -15, -56, -34,   2,  13,
         29,  -1, -20,  -7,  -8,  -4, -38, -29,
         -9,  24,   2, -16, -20,   6,  22, -22,
        -17, -20, -12, -27, -30, -25, -14, -36,
        -49,  -1, -27, -39, -46, -44, -33, -51,
        -14, -14, -22, -46, -44, -30, -15, -27,
          1,   7,  -8, -64, -43, -16,   9,   8,
        -15,  36,  12, -54,   8, -28,  24,  14
    }
}

local PESTO_EG = {
    [1] = {
          0,   0,   0,   0,   0,   0,   0,   0,
        178, 173, 158, 134, 147, 132, 165, 187,
         94, 100,  85,  67,  56,  53,  82,  84,
         32,  24,  13,   5,  -2,   4,  17,  17,
         13,   9,  -3,  -7,  -7,  -8,   3,  -1,
          4,   7,  -6,   1,   0,  -5,  -1,  -8,
         13,   8,   8,  10,  13,   0,   2,  -7,
          0,   0,   0,   0,   0,   0,   0,   0
    },
    [2] = {
        -58, -38, -13, -28, -31, -27, -63, -99,
        -25,  -8, -25,  -2,  -9, -25, -24, -52,
        -24, -20,  10,   9,  -1,  -9, -19, -41,
        -17,   3,  22,  22,  22,  11,   8, -18,
        -18,  -6,  16,  25,  16,  17,   4, -18,
        -23,  -3,  -1,  15,  10,  -3, -20, -22,
        -42, -20, -10,  -5,  -2, -20, -23, -44,
        -29, -51, -23, -15, -22, -18, -50, -64
    },
    [3] = {
        -14, -21, -11,  -8,  -7,  -9, -17, -24,
         -8,  -4,   7, -12,  -3, -13,  -4, -14,
          2,  -8,   0,  -1,  -2,   6,   0,   4,
         -3,   9,  12,   9,  14,  10,   3,   2,
         -6,   3,  13,  19,   7,  10,  -3,  -9,
        -12,  -3,   8,  10,  13,   3,  -7, -15,
        -14, -18,  -7,  -1,   4,  -9, -15, -27,
        -23,  -9, -23,  -5,  -9, -16,  -5, -17
    },
    [4] = {
         13,  10,  18,  15,  12,  12,   8,   5,
         11,  13,  13,  11,  -3,   3,   8,   3,
          7,   7,   7,   5,   4,  -3,  -5,  -3,
          4,   3,  13,   1,   2,   1,  -1,   2,
          3,   5,   8,   4,  -5,  -6,  -8, -11,
         -4,   0,  -5,  -1,  -7, -12,  -8, -16,
         -6,  -6,   0,   2,  -9,  -9, -11,  -3,
         -9,   2,   3,  -1,  -5, -13,   4, -20
    },
    [5] = {
         -9,  22,  22,  27,  27,  19,  10,  20,
        -17,  20,  32,  41,  58,  25,  30,   0,
        -20,   6,   9,  49,  47,  35,  19,   9,
          3,  22,  24,  45,  57,  40,  57,  36,
        -18,  28,  19,  47,  31,  34,  39,  23,
        -16, -27,  15,   6,   9,  17,  10,   5,
        -22, -23, -30, -16, -16, -23, -36, -32,
        -33, -28, -22, -43,  -5, -32, -20, -41
    },
    [6] = {
        -74, -35, -18, -18, -11,  15,   4, -17,
        -12,  17,  14,  17,  17,  38,  23,  11,
         10,  17,  23,  15,  20,  45,  44,  13,
         -8,  22,  24,  27,  26,  33,  26,   3,
        -18,  -4,  21,  24,  27,  23,   9, -11,
        -19,  -3,  11,  21,  23,  16,   7,  -9,
        -27, -11,   4,  13,  14,   4,  -5, -17,
        -53, -34, -21, -11, -28, -14, -24, -43
    }
}

local MG_TABLE = {}
local EG_TABLE = {}
for p = 1, 12 do
    MG_TABLE[p] = {}
    EG_TABLE[p] = {}
    local p_type = PIECE_TYPE[p]
    local p_color = PIECE_COLOR[p]
    for sq = 1, 120 do
        if SQ_TO_COORD[sq] then
            local r = floor(sq / 10) - 1
            local f = sq % 10
            local sq64 = (p_color == WHITE) and ((8 - r) * 8 + (f - 1) + 1) or ((r - 1) * 8 + (f - 1) + 1)
            MG_TABLE[p][sq] = MG_VALUE[p_type] + PESTO_MG[p_type][sq64]
            EG_TABLE[p][sq] = EG_VALUE[p_type] + PESTO_EG[p_type][sq64]
        else
            MG_TABLE[p][sq] = 0
            EG_TABLE[p][sq] = 0
        end
    end
end

-- ----------------------------------------------------------------------------
-- Engine State & Memory Structures
-- ----------------------------------------------------------------------------
local board = {}
for sq = 1, 120 do board[sq] = OFFBOARD end

local king_sq = { [WHITE] = 0, [BLACK] = 0 }
local side = WHITE
local castling = 15
local ep_sq = 0
local halfmove = 0
local fullmove = 1
local zobrist_key = 0

local mg_score = { [WHITE] = 0, [BLACK] = 0 }
local eg_score = { [WHITE] = 0, [BLACK] = 0 }
local game_phase = 0

-- Piece counts for non-pawn material check
local piece_counts = {}
for p = 1, 12 do piece_counts[p] = 0 end

-- History of root game for 3-fold repetition
local rep_keys = {}
local rep_len = 0

-- Undo Stack
local MAX_PLY = 128
local undo_captured = {}
local undo_castling = {}
local undo_ep       = {}
local undo_halfmove = {}
local undo_key      = {}
local undo_mg_w     = {}
local undo_mg_b     = {}
local undo_eg_w     = {}
local undo_eg_b     = {}
local undo_phase    = {}

for i = 0, MAX_PLY do
    undo_captured[i] = 0
    undo_castling[i] = 0
    undo_ep[i]       = 0
    undo_halfmove[i] = 0
    undo_key[i]      = 0
    undo_mg_w[i]     = 0
    undo_mg_b[i]     = 0
    undo_eg_w[i]     = 0
    undo_eg_b[i]     = 0
    undo_phase[i]    = 0
end

-- Move Generation Stack
local MAX_MOVES = 256 * (128 + 2)
local move_stack  = {}
local score_stack = {}
local move_head   = {}

for i = 1, MAX_MOVES do
    move_stack[i]  = 0
    score_stack[i] = 0
end
for i = 0, MAX_PLY do
    move_head[i] = 1
end

-- Move Ordering Heuristics
local killer_moves = {}
for i = 0, MAX_PLY do
    killer_moves[i] = { 0, 0 }
end

local history_heuristic = {}
for p = 1, 12 do
    history_heuristic[p] = {}
    for sq = 1, 120 do
        history_heuristic[p][sq] = 0
    end
end

-- ----------------------------------------------------------------------------
-- Transposition Table (Flat Arrays for Zero GC Pressure)
-- ----------------------------------------------------------------------------
local TT_SIZE = 262144 -- 2^18 entries (~12MB)
local TT_EXACT = 0
local TT_LOWER = 1
local TT_UPPER = 2

local tt_key   = {}
local tt_depth = {}
local tt_score = {}
local tt_flag  = {}
local tt_move  = {}

local function clear_tt()
    for i = 1, TT_SIZE do
        tt_key[i]   = -1
        tt_depth[i] = -1
        tt_score[i] = 0
        tt_flag[i]  = 0
        tt_move[i]  = 0
    end
end
clear_tt()

local function clear_heuristics()
    for i = 0, MAX_PLY do
        killer_moves[i][1] = 0
        killer_moves[i][2] = 0
    end
    for p = 1, 12 do
        for sq = 1, 120 do
            history_heuristic[p][sq] = 0
        end
    end
end

-- ----------------------------------------------------------------------------
-- Board Setup, FEN Parsing, Evaluation
-- ----------------------------------------------------------------------------
local START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

local function reset_board()
    for sq = 1, 120 do
        board[sq] = SQ_TO_COORD[sq] and EMPTY or OFFBOARD
    end
    for p = 1, 12 do piece_counts[p] = 0 end
    king_sq[WHITE] = 0
    king_sq[BLACK] = 0
    side = WHITE
    castling = 0
    ep_sq = 0
    halfmove = 0
    fullmove = 1
    zobrist_key = 0
    mg_score[WHITE] = 0
    mg_score[BLACK] = 0
    eg_score[WHITE] = 0
    eg_score[BLACK] = 0
    game_phase = 0
    rep_len = 0
end

local function compute_full_eval_and_key()
    mg_score[WHITE] = 0
    mg_score[BLACK] = 0
    eg_score[WHITE] = 0
    eg_score[BLACK] = 0
    game_phase = 0
    for p = 1, 12 do piece_counts[p] = 0 end
    local key = 0

    for sq = 1, 120 do
        local p = board[sq]
        if p ~= EMPTY and p ~= OFFBOARD then
            local c = PIECE_COLOR[p]
            local t = PIECE_TYPE[p]
            piece_counts[p] = piece_counts[p] + 1
            mg_score[c] = mg_score[c] + MG_TABLE[p][sq]
            eg_score[c] = eg_score[c] + EG_TABLE[p][sq]
            game_phase = game_phase + GAME_PHASE_INC[t]
            key = bxor(key, ZOBRIST_PIECE[p][sq])
            if t == 6 then
                king_sq[c] = sq
            end
        end
    end

    if side == BLACK then key = bxor(key, ZOBRIST_SIDE) end
    key = bxor(key, ZOBRIST_CASTLING[castling])
    key = bxor(key, ZOBRIST_EP[ep_sq ~= 0 and (ep_sq % 10) or 0])

    zobrist_key = key
end

local function load_fen(fen)
    reset_board()
    fen = fen or START_FEN
    local parts = {}
    for part in fen:gmatch("%S+") do parts[#parts + 1] = part end

    local placement = parts[1] or ""
    local r, f = 8, 1
    for i = 1, #placement do
        local ch = str_sub(placement, i, i)
        if ch == "/" then
            r = r - 1
            f = 1
        elseif ch >= "1" and ch <= "8" then
            f = f + tonumber(ch)
        else
            local p = CHAR_TO_PIECE[ch]
            if p then
                local sq = (r + 1) * 10 + f
                board[sq] = p
                f = f + 1
            end
        end
    end

    side = (parts[2] == "b") and BLACK or WHITE

    castling = 0
    local c_str = parts[3] or "-"
    if str_find(c_str, "K") then castling = castling + CASTLE_WK end
    if str_find(c_str, "Q") then castling = castling + CASTLE_WQ end
    if str_find(c_str, "k") then castling = castling + CASTLE_BK end
    if str_find(c_str, "q") then castling = castling + CASTLE_BQ end

    local ep_str = parts[4] or "-"
    ep_sq = (ep_str ~= "-" and COORD_TO_SQ[ep_str]) and COORD_TO_SQ[ep_str] or 0

    halfmove = tonumber(parts[5]) or 0
    fullmove = tonumber(parts[6]) or 1

    compute_full_eval_and_key()
    rep_len = 1
    rep_keys[1] = zobrist_key
end

local function print_board()
    print("\n   +------------------------+")
    for r = 8, 1, -1 do
        local line = " " .. r .. " |"
        for f = 1, 8 do
            local sq = (r + 1) * 10 + f
            local p = board[sq]
            line = line .. " " .. PIECE_TO_CHAR[p] .. " "
        end
        print(line .. "|")
    end
    print("   +------------------------+")
    print("     a  b  c  d  e  f  g  h\n")
    print(str_format("Side to move: %s | Castling: %d | EP: %s | Zobrist: %u",
        (side == WHITE and "White" or "Black"), castling,
        (ep_sq ~= 0 and SQ_TO_COORD[ep_sq] or "-"), zobrist_key))
end

-- Fast Leaf Evaluation: O(1)
local function evaluate()
    local mg = mg_score[side] - mg_score[1 - side]
    local eg = eg_score[side] - eg_score[1 - side]
    local p = game_phase
    if p > 24 then p = 24 end
    return floor((mg * p + eg * (24 - p)) / 24)
end

-- ----------------------------------------------------------------------------
-- Attack Detection & King Safety
-- ----------------------------------------------------------------------------
local function is_square_attacked(sq, by_color)
    -- Pawns
    if by_color == WHITE then
        if board[sq - 11] == W_PAWN or board[sq - 9] == W_PAWN then return true end
    else
        if board[sq + 11] == B_PAWN or board[sq + 9] == B_PAWN then return true end
    end

    -- Knights
    local enemy_knight = (by_color == WHITE) and W_KNIGHT or B_KNIGHT
    for k = 1, 8 do
        if board[sq + KNIGHT_DELTAS[k]] == enemy_knight then return true end
    end

    -- King
    local enemy_king = (by_color == WHITE) and W_KING or B_KING
    for k = 1, 8 do
        if board[sq + KING_DELTAS[k]] == enemy_king then return true end
    end

    -- Bishops & Queens
    local enemy_bishop = (by_color == WHITE) and W_BISHOP or B_BISHOP
    local enemy_queen  = (by_color == WHITE) and W_QUEEN or B_QUEEN
    for k = 1, 4 do
        local delta = BISHOP_DELTAS[k]
        local dest = sq + delta
        while true do
            local p = board[dest]
            if p == OFFBOARD then break end
            if p ~= EMPTY then
                if p == enemy_bishop or p == enemy_queen then return true end
                break
            end
            dest = dest + delta
        end
    end

    -- Rooks & Queens
    local enemy_rook = (by_color == WHITE) and W_ROOK or B_ROOK
    for k = 1, 4 do
        local delta = ROOK_DELTAS[k]
        local dest = sq + delta
        while true do
            local p = board[dest]
            if p == OFFBOARD then break end
            if p ~= EMPTY then
                if p == enemy_rook or p == enemy_queen then return true end
                break
            end
            dest = dest + delta
        end
    end

    return false
end

local function in_check(c)
    return is_square_attacked(king_sq[c], 1 - c)
end

-- ----------------------------------------------------------------------------
-- Move Generation
-- ----------------------------------------------------------------------------
local function generate_moves(ply, captures_only)
    local count = move_head[ply]
    local enemy_color = 1 - side

    if side == WHITE then
        for sq = 31, 88 do
            if board[sq] == W_PAWN then
                local rank = floor(sq / 10) - 1

                -- Single Push
                local dest = sq + NORTH
                if captures_only and rank == 7 and board[dest] == EMPTY then
                    move_stack[count] = pack_move(sq, dest, W_QUEEN, FLAG_NORMAL); count = count + 1
                elseif board[dest] == EMPTY and not captures_only then
                    if rank == 7 then
                        move_stack[count] = pack_move(sq, dest, W_QUEEN,  FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_ROOK,   FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_BISHOP, FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_KNIGHT, FLAG_NORMAL); count = count + 1
                    else
                        move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                        if rank == 2 and board[dest + NORTH] == EMPTY then
                            move_stack[count] = pack_move(sq, dest + NORTH, 0, FLAG_DOUBLE); count = count + 1
                        end
                    end
                end

                -- Captures: NW (+9)
                local cap_sq = sq + 9
                local target = board[cap_sq]
                if target ~= OFFBOARD then
                    if target ~= EMPTY and PIECE_COLOR[target] == enemy_color then
                        if rank == 7 then
                            move_stack[count] = pack_move(sq, cap_sq, W_QUEEN,  FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_ROOK,   FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_BISHOP, FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_KNIGHT, FLAG_NORMAL); count = count + 1
                        else
                            move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_NORMAL); count = count + 1
                        end
                    elseif cap_sq == ep_sq then
                        move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_EP); count = count + 1
                    end
                end

                -- Captures: NE (+11)
                cap_sq = sq + 11
                target = board[cap_sq]
                if target ~= OFFBOARD then
                    if target ~= EMPTY and PIECE_COLOR[target] == enemy_color then
                        if rank == 7 then
                            move_stack[count] = pack_move(sq, cap_sq, W_QUEEN,  FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_ROOK,   FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_BISHOP, FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_KNIGHT, FLAG_NORMAL); count = count + 1
                        else
                            move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_NORMAL); count = count + 1
                        end
                    elseif cap_sq == ep_sq then
                        move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_EP); count = count + 1
                    end
                end
            end
        end
    else
        for sq = 31, 88 do
            if board[sq] == B_PAWN then
                local rank = floor(sq / 10) - 1

                -- Single Push
                local dest = sq + SOUTH
                if captures_only and rank == 2 and board[dest] == EMPTY then
                    move_stack[count] = pack_move(sq, dest, W_QUEEN, FLAG_NORMAL); count = count + 1
                elseif board[dest] == EMPTY and not captures_only then
                    if rank == 2 then
                        move_stack[count] = pack_move(sq, dest, W_QUEEN,  FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_ROOK,   FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_BISHOP, FLAG_NORMAL); count = count + 1
                        move_stack[count] = pack_move(sq, dest, W_KNIGHT, FLAG_NORMAL); count = count + 1
                    else
                        move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                        if rank == 7 and board[dest + SOUTH] == EMPTY then
                            move_stack[count] = pack_move(sq, dest + SOUTH, 0, FLAG_DOUBLE); count = count + 1
                        end
                    end
                end

                -- Captures: SW (-11)
                local cap_sq = sq - 11
                local target = board[cap_sq]
                if target ~= OFFBOARD then
                    if target ~= EMPTY and PIECE_COLOR[target] == enemy_color then
                        if rank == 2 then
                            move_stack[count] = pack_move(sq, cap_sq, W_QUEEN,  FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_ROOK,   FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_BISHOP, FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_KNIGHT, FLAG_NORMAL); count = count + 1
                        else
                            move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_NORMAL); count = count + 1
                        end
                    elseif cap_sq == ep_sq then
                        move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_EP); count = count + 1
                    end
                end

                -- Captures: SE (-9)
                cap_sq = sq - 9
                target = board[cap_sq]
                if target ~= OFFBOARD then
                    if target ~= EMPTY and PIECE_COLOR[target] == enemy_color then
                        if rank == 2 then
                            move_stack[count] = pack_move(sq, cap_sq, W_QUEEN,  FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_ROOK,   FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_BISHOP, FLAG_NORMAL); count = count + 1
                            move_stack[count] = pack_move(sq, cap_sq, W_KNIGHT, FLAG_NORMAL); count = count + 1
                        else
                            move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_NORMAL); count = count + 1
                        end
                    elseif cap_sq == ep_sq then
                        move_stack[count] = pack_move(sq, cap_sq, 0, FLAG_EP); count = count + 1
                    end
                end
            end
        end
    end

    -- Non-Pawns
    for sq = 21, 98 do
        local p = board[sq]
        if p ~= EMPTY and p ~= OFFBOARD and PIECE_COLOR[p] == side then
            local p_type = PIECE_TYPE[p]

            if p_type == 2 then
                for k = 1, 8 do
                    local dest = sq + KNIGHT_DELTAS[k]
                    local target = board[dest]
                    if target ~= OFFBOARD then
                        if target == EMPTY then
                            if not captures_only then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                        elseif PIECE_COLOR[target] == enemy_color then
                            move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                        end
                    end
                end

            elseif p_type == 3 then
                for k = 1, 4 do
                    local delta = BISHOP_DELTAS[k]
                    local dest = sq + delta
                    while true do
                        local target = board[dest]
                        if target == OFFBOARD then break end
                        if target == EMPTY then
                            if not captures_only then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                        else
                            if PIECE_COLOR[target] == enemy_color then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                            break
                        end
                        dest = dest + delta
                    end
                end

            elseif p_type == 4 then
                for k = 1, 4 do
                    local delta = ROOK_DELTAS[k]
                    local dest = sq + delta
                    while true do
                        local target = board[dest]
                        if target == OFFBOARD then break end
                        if target == EMPTY then
                            if not captures_only then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                        else
                            if PIECE_COLOR[target] == enemy_color then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                            break
                        end
                        dest = dest + delta
                    end
                end

            elseif p_type == 5 then
                for k = 1, 8 do
                    local delta = KING_DELTAS[k]
                    local dest = sq + delta
                    while true do
                        local target = board[dest]
                        if target == OFFBOARD then break end
                        if target == EMPTY then
                            if not captures_only then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                        else
                            if PIECE_COLOR[target] == enemy_color then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                            break
                        end
                        dest = dest + delta
                    end
                end

            elseif p_type == 6 then
                for k = 1, 8 do
                    local dest = sq + KING_DELTAS[k]
                    local target = board[dest]
                    if target ~= OFFBOARD then
                        if target == EMPTY then
                            if not captures_only then
                                move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                            end
                        elseif PIECE_COLOR[target] == enemy_color then
                            move_stack[count] = pack_move(sq, dest, 0, FLAG_NORMAL); count = count + 1
                        end
                    end
                end
            end
        end
    end

    -- Castling
    if not captures_only then
        if side == WHITE then
            local e1 = 25
            if board[e1] == W_KING and not is_square_attacked(e1, BLACK) then
                if (castling % 2 >= 1) and board[26] == EMPTY and board[27] == EMPTY and board[28] == W_ROOK then
                    if not is_square_attacked(26, BLACK) and not is_square_attacked(27, BLACK) then
                        move_stack[count] = pack_move(e1, 27, 0, FLAG_CASTLE); count = count + 1
                    end
                end
                if (floor(castling / 2) % 2 == 1) and board[24] == EMPTY and board[23] == EMPTY and board[22] == EMPTY and board[21] == W_ROOK then
                    if not is_square_attacked(24, BLACK) and not is_square_attacked(23, BLACK) then
                        move_stack[count] = pack_move(e1, 23, 0, FLAG_CASTLE); count = count + 1
                    end
                end
            end
        else
            local e8 = 95
            if board[e8] == B_KING and not is_square_attacked(e8, WHITE) then
                if (floor(castling / 4) % 2 == 1) and board[96] == EMPTY and board[97] == EMPTY and board[98] == B_ROOK then
                    if not is_square_attacked(96, WHITE) and not is_square_attacked(97, WHITE) then
                        move_stack[count] = pack_move(e8, 97, 0, FLAG_CASTLE); count = count + 1
                    end
                end
                if (floor(castling / 8) % 2 == 1) and board[94] == EMPTY and board[93] == EMPTY and board[92] == EMPTY and board[91] == B_ROOK then
                    if not is_square_attacked(94, WHITE) and not is_square_attacked(93, WHITE) then
                        move_stack[count] = pack_move(e8, 93, 0, FLAG_CASTLE); count = count + 1
                    end
                end
            end
        end
    end

    move_head[ply + 1] = count
end

-- ----------------------------------------------------------------------------
-- Make / Unmake Move
-- ----------------------------------------------------------------------------
local function make_move(move, ply)
    local from_sq = move_from(move)
    local to_sq   = move_to(move)
    local promo   = move_promo(move)
    local flag    = move_flag(move)

    local p = board[from_sq]
    local captured = board[to_sq]

    undo_captured[ply] = captured
    undo_castling[ply] = castling
    undo_ep[ply]       = ep_sq
    undo_halfmove[ply] = halfmove
    undo_key[ply]      = zobrist_key
    undo_mg_w[ply]     = mg_score[WHITE]
    undo_mg_b[ply]     = mg_score[BLACK]
    undo_eg_w[ply]     = eg_score[WHITE]
    undo_eg_b[ply]     = eg_score[BLACK]
    undo_phase[ply]    = game_phase

    local c = side
    local enemy = 1 - c
    local p_type = PIECE_TYPE[p]

    -- Remove piece from from_sq
    board[from_sq] = EMPTY
    mg_score[c] = mg_score[c] - MG_TABLE[p][from_sq]
    eg_score[c] = eg_score[c] - EG_TABLE[p][from_sq]
    zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[p][from_sq])

    -- Normal capture
    if captured ~= EMPTY then
        local cap_type = PIECE_TYPE[captured]
        piece_counts[captured] = piece_counts[captured] - 1
        mg_score[enemy] = mg_score[enemy] - MG_TABLE[captured][to_sq]
        eg_score[enemy] = eg_score[enemy] - EG_TABLE[captured][to_sq]
        game_phase = game_phase - GAME_PHASE_INC[cap_type]
        zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[captured][to_sq])
        halfmove = 0
    elseif p_type == 1 then
        halfmove = 0
    else
        halfmove = halfmove + 1
    end

    -- En Passant capture
    if flag == FLAG_EP then
        local cap_sq = (c == WHITE) and (to_sq - NORTH) or (to_sq + NORTH)
        local cap_pawn = board[cap_sq]
        piece_counts[cap_pawn] = piece_counts[cap_pawn] - 1
        board[cap_sq] = EMPTY
        mg_score[enemy] = mg_score[enemy] - MG_TABLE[cap_pawn][cap_sq]
        eg_score[enemy] = eg_score[enemy] - EG_TABLE[cap_pawn][cap_sq]
        zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[cap_pawn][cap_sq])

    -- Castling move
    elseif flag == FLAG_CASTLE then
        if to_sq == 27 then
            board[28] = EMPTY; board[26] = W_ROOK
            mg_score[WHITE] = mg_score[WHITE] - MG_TABLE[W_ROOK][28] + MG_TABLE[W_ROOK][26]
            eg_score[WHITE] = eg_score[WHITE] - EG_TABLE[W_ROOK][28] + EG_TABLE[W_ROOK][26]
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[W_ROOK][28])
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[W_ROOK][26])
        elseif to_sq == 23 then
            board[21] = EMPTY; board[24] = W_ROOK
            mg_score[WHITE] = mg_score[WHITE] - MG_TABLE[W_ROOK][21] + MG_TABLE[W_ROOK][24]
            eg_score[WHITE] = eg_score[WHITE] - EG_TABLE[W_ROOK][21] + EG_TABLE[W_ROOK][24]
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[W_ROOK][21])
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[W_ROOK][24])
        elseif to_sq == 97 then
            board[98] = EMPTY; board[96] = B_ROOK
            mg_score[BLACK] = mg_score[BLACK] - MG_TABLE[B_ROOK][98] + MG_TABLE[B_ROOK][96]
            eg_score[BLACK] = eg_score[BLACK] - EG_TABLE[B_ROOK][98] + EG_TABLE[B_ROOK][96]
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[B_ROOK][98])
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[B_ROOK][96])
        elseif to_sq == 93 then
            board[91] = EMPTY; board[94] = B_ROOK
            mg_score[BLACK] = mg_score[BLACK] - MG_TABLE[B_ROOK][91] + MG_TABLE[B_ROOK][94]
            eg_score[BLACK] = eg_score[BLACK] - EG_TABLE[B_ROOK][91] + EG_TABLE[B_ROOK][94]
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[B_ROOK][91])
            zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[B_ROOK][94])
        end
    end

    -- Place final piece on to_sq
    local final_piece = p
    if promo > 0 then
        piece_counts[p] = piece_counts[p] - 1
        final_piece = (c == WHITE) and promo or (promo + 6)
        piece_counts[final_piece] = piece_counts[final_piece] + 1
        game_phase = game_phase + GAME_PHASE_INC[promo]
    end

    board[to_sq] = final_piece
    mg_score[c] = mg_score[c] + MG_TABLE[final_piece][to_sq]
    eg_score[c] = eg_score[c] + EG_TABLE[final_piece][to_sq]
    zobrist_key = bxor(zobrist_key, ZOBRIST_PIECE[final_piece][to_sq])

    if p_type == 6 then king_sq[c] = to_sq end

    -- Update castling rights
    zobrist_key = bxor(zobrist_key, ZOBRIST_CASTLING[castling])
    castling = CASTLE_AND[castling][CASTLE_RIGHTS_MASK[from_sq]]
    castling = CASTLE_AND[castling][CASTLE_RIGHTS_MASK[to_sq]]
    zobrist_key = bxor(zobrist_key, ZOBRIST_CASTLING[castling])

    -- Update En Passant
    zobrist_key = bxor(zobrist_key, ZOBRIST_EP[ep_sq ~= 0 and (ep_sq % 10) or 0])
    if flag == FLAG_DOUBLE then
        ep_sq = (from_sq + to_sq) / 2
        zobrist_key = bxor(zobrist_key, ZOBRIST_EP[ep_sq % 10])
    else
        ep_sq = 0
        zobrist_key = bxor(zobrist_key, ZOBRIST_EP[0])
    end

    -- Switch side
    side = enemy
    zobrist_key = bxor(zobrist_key, ZOBRIST_SIDE)

    -- King Safety Check
    if is_square_attacked(king_sq[c], enemy) then
        -- Illegal move: revert
        side = c
        zobrist_key = undo_key[ply]
        if p_type == 6 then king_sq[c] = from_sq end
        if promo > 0 then
            piece_counts[final_piece] = piece_counts[final_piece] - 1
            piece_counts[p] = piece_counts[p] + 1
        end

        board[from_sq] = p
        board[to_sq]   = captured
        if captured ~= EMPTY then
            piece_counts[captured] = piece_counts[captured] + 1
        end

        if flag == FLAG_EP then
            local cap_sq = (c == WHITE) and (to_sq - NORTH) or (to_sq + NORTH)
            local cap_pawn = (c == WHITE) and B_PAWN or W_PAWN
            board[cap_sq] = cap_pawn
            piece_counts[cap_pawn] = piece_counts[cap_pawn] + 1
        elseif flag == FLAG_CASTLE then
            if to_sq == 27 then board[28] = W_ROOK; board[26] = EMPTY
            elseif to_sq == 23 then board[21] = W_ROOK; board[24] = EMPTY
            elseif to_sq == 97 then board[98] = B_ROOK; board[96] = EMPTY
            elseif to_sq == 93 then board[91] = B_ROOK; board[94] = EMPTY
            end
        end

        castling        = undo_castling[ply]
        ep_sq           = undo_ep[ply]
        halfmove        = undo_halfmove[ply]
        mg_score[WHITE] = undo_mg_w[ply]
        mg_score[BLACK] = undo_mg_b[ply]
        eg_score[WHITE] = undo_eg_w[ply]
        eg_score[BLACK] = undo_eg_b[ply]
        game_phase      = undo_phase[ply]
        return false
    end

    return true
end

local function unmake_move(move, ply)
    local from_sq = move_from(move)
    local to_sq   = move_to(move)
    local promo   = move_promo(move)
    local flag    = move_flag(move)

    local prev_side = 1 - side
    local captured = undo_captured[ply]
    local moving_piece = board[to_sq]

    local original_piece = (promo > 0) and ((prev_side == WHITE) and W_PAWN or B_PAWN) or moving_piece

    if promo > 0 then
        piece_counts[moving_piece] = piece_counts[moving_piece] - 1
        piece_counts[original_piece] = piece_counts[original_piece] + 1
    end

    board[from_sq] = original_piece
    board[to_sq]   = captured

    if captured ~= EMPTY then
        piece_counts[captured] = piece_counts[captured] + 1
    end

    if PIECE_TYPE[original_piece] == 6 then
        king_sq[prev_side] = from_sq
    end

    if flag == FLAG_EP then
        local cap_sq = (prev_side == WHITE) and (to_sq - NORTH) or (to_sq + NORTH)
        local cap_pawn = (prev_side == WHITE) and B_PAWN or W_PAWN
        board[cap_sq] = cap_pawn
        piece_counts[cap_pawn] = piece_counts[cap_pawn] + 1
    elseif flag == FLAG_CASTLE then
        if to_sq == 27 then board[28] = W_ROOK; board[26] = EMPTY
        elseif to_sq == 23 then board[21] = W_ROOK; board[24] = EMPTY
        elseif to_sq == 97 then board[98] = B_ROOK; board[96] = EMPTY
        elseif to_sq == 93 then board[91] = B_ROOK; board[94] = EMPTY
        end
    end

    side            = prev_side
    castling        = undo_castling[ply]
    ep_sq           = undo_ep[ply]
    halfmove        = undo_halfmove[ply]
    zobrist_key     = undo_key[ply]
    mg_score[WHITE] = undo_mg_w[ply]
    mg_score[BLACK] = undo_mg_b[ply]
    eg_score[WHITE] = undo_eg_w[ply]
    eg_score[BLACK] = undo_eg_b[ply]
    game_phase      = undo_phase[ply]
end

-- Null Move implementation for Null Move Pruning (NMP)
local function make_null_move(ply)
    undo_ep[ply]       = ep_sq
    undo_key[ply]      = zobrist_key
    undo_halfmove[ply] = halfmove
    halfmove = 0 -- a null move must not create repetitions with positions before it

    zobrist_key = bxor(zobrist_key, ZOBRIST_EP[ep_sq ~= 0 and (ep_sq % 10) or 0])
    ep_sq = 0
    zobrist_key = bxor(zobrist_key, ZOBRIST_EP[0])

    side = 1 - side
    zobrist_key = bxor(zobrist_key, ZOBRIST_SIDE)
end

local function unmake_null_move(ply)
    side = 1 - side
    ep_sq = undo_ep[ply]
    zobrist_key = undo_key[ply]
    halfmove = undo_halfmove[ply]
end

-- Has non-pawn material (to avoid zugzwang when null-move pruning)
local function has_non_pawn_material(c)
    local offset = (c == WHITE) and 0 or 6
    return (piece_counts[W_KNIGHT + offset] > 0 or
            piece_counts[W_BISHOP + offset] > 0 or
            piece_counts[W_ROOK + offset] > 0 or
            piece_counts[W_QUEEN + offset] > 0)
end

-- ----------------------------------------------------------------------------
-- Move Scoring & Ordering
-- ----------------------------------------------------------------------------
local MVV_LVA_VICTIM = { [1] = 100, [2] = 300, [3] = 300, [4] = 500, [5] = 900, [6] = 10000 }
local MVV_LVA_ATTACKER = { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6 }

local function score_moves(ply, tt_suggested_move)
    local head = move_head[ply]
    local tail = move_head[ply + 1] - 1
    local killer1 = killer_moves[ply][1]
    local killer2 = killer_moves[ply][2]

    for i = head, tail do
        local m = move_stack[i]
        local score = 0

        if m == tt_suggested_move then
            score = 2000000
        else
            local from_sq = move_from(m)
            local to_sq = move_to(m)
            local captured = board[to_sq]
            local flag = move_flag(m)
            local promo = move_promo(m)

            if captured ~= EMPTY then
                local vic = PIECE_TYPE[captured]
                local att = PIECE_TYPE[board[from_sq]]
                score = 1000000 + (MVV_LVA_VICTIM[vic] or 0) * 10 - (MVV_LVA_ATTACKER[att] or 0)
            elseif flag == FLAG_EP then
                score = 1000000 + 1000 - 1
            elseif promo > 0 then
                score = 900000 + (promo == W_QUEEN and 50000 or 0)
            elseif m == killer1 then
                score = 800000
            elseif m == killer2 then
                score = 700000
            else
                local p = board[from_sq]
                score = history_heuristic[p][to_sq] or 0
            end
        end

        score_stack[i] = score
    end
end

-- ----------------------------------------------------------------------------
-- Search Engine: Quiescence, Negamax Alpha-Beta with Iterative Deepening
-- ----------------------------------------------------------------------------
local INFINITY   = 1000000
local MATE_SCORE = 100000
local MAX_SEARCH_PLY = 120                 -- hard ply cap (stacks hold MAX_PLY = 128)
local MATE_BOUND = MATE_SCORE - 2 * MAX_SEARCH_PLY

-- Optional hook polled during search so a UCI "stop" can interrupt the search.
local stop_poll = nil

local nodes_searched = 0
local search_start_time = 0
local search_stop_time = 0
local stop_search = false

local function check_time()
    if clock() >= search_stop_time or (stop_poll and stop_poll()) then
        stop_search = true
    end
end

-- Repetition & 50-move check.
-- Positions repeat only with the same side to move, so we step back two plies
-- at a time, and never past the last irreversible move (halfmove reset).
-- Inside the search a single repetition is scored as a draw (standard practice);
-- positions are tracked in a flat key stack covering game history + search path.

local function is_repetition_or_50move(ply)
    if halfmove >= 100 then return true end
    local top = rep_len + ply          -- index of the current position
    local limit = top - halfmove
    if limit < 1 then limit = 1 end
    local i = top - 2
    while i >= limit do
        if rep_keys[i] == zobrist_key then return true end
        i = i - 2
    end
    return false
end

-- Quiescence Search (QS) with Delta Pruning
local function quiesce(alpha, beta, ply)
    nodes_searched = nodes_searched + 1
    if (nodes_searched % 2048 == 0) then check_time() end
    if stop_search then return 0 end

    local stand_pat = evaluate()
    if ply >= MAX_SEARCH_PLY then return stand_pat end
    if stand_pat >= beta then return beta end
    if stand_pat > alpha then alpha = stand_pat end

    -- Delta Pruning: even winning a queen cannot raise alpha
    if stand_pat < alpha - 1100 then
        return alpha
    end

    generate_moves(ply, true)
    score_moves(ply, 0)

    local head = move_head[ply]
    local tail = move_head[ply + 1] - 1

    for i = head, tail do
        local best_idx = i
        local best_sc = score_stack[i]
        for j = i + 1, tail do
            if score_stack[j] > best_sc then
                best_sc = score_stack[j]
                best_idx = j
            end
        end
        if best_idx ~= i then
            local tm = move_stack[i]; move_stack[i] = move_stack[best_idx]; move_stack[best_idx] = tm
            local ts = score_stack[i]; score_stack[i] = score_stack[best_idx]; score_stack[best_idx] = ts
        end

        local m = move_stack[i]
        if make_move(m, ply) then
            local score = -quiesce(-beta, -alpha, ply + 1)
            unmake_move(m, ply)

            if stop_search then return 0 end
            if score >= beta then return beta end
            if score > alpha then alpha = score end
        end
    end

    return alpha
end

local root_best_move = 0

-- Negamax Alpha-Beta with Transposition Table, NMP, and LMR
local function negamax(alpha, beta, depth, ply, can_null)
    if (nodes_searched % 2048 == 0) then check_time() end
    if stop_search then return 0 end

    rep_keys[rep_len + ply] = zobrist_key

    if ply > 0 then
        if is_repetition_or_50move(ply) then return 0 end
        -- Mate distance pruning
        local mate_alpha = -MATE_SCORE + ply
        local mate_beta  = MATE_SCORE - ply - 1
        if alpha < mate_alpha then alpha = mate_alpha end
        if beta > mate_beta then beta = mate_beta end
        if alpha >= beta then return alpha end
    end

    if ply >= MAX_SEARCH_PLY then return evaluate() end

    local in_chk = in_check(side)

    -- Check Extension (bounded so the search depth cannot run away)
    if in_chk and ply < MAX_SEARCH_PLY - 8 then depth = depth + 1 end

    if depth <= 0 then
        return quiesce(alpha, beta, ply)
    end

    nodes_searched = nodes_searched + 1

    -- Transposition Table Probe
    local tt_idx = (zobrist_key % TT_SIZE) + 1
    local tt_suggested_move = 0

    if tt_key[tt_idx] == zobrist_key then
        tt_suggested_move = tt_move[tt_idx]
        if ply > 0 and tt_depth[tt_idx] >= depth then
            local t_score = tt_score[tt_idx]
            if t_score > MATE_BOUND then t_score = t_score - ply
            elseif t_score < -MATE_BOUND then t_score = t_score + ply end

            local t_flag = tt_flag[tt_idx]
            if t_flag == TT_EXACT then
                return t_score
            elseif t_flag == TT_LOWER and t_score >= beta then
                return t_score
            elseif t_flag == TT_UPPER and t_score <= alpha then
                return t_score
            end
        end
    end

    -- Null Move Pruning (NMP)
    if can_null and not in_chk and depth >= 3 and ply > 0 and beta < MATE_BOUND
       and has_non_pawn_material(side) and evaluate() >= beta then
        -- No moves were generated at this ply yet: give the child a fresh
        -- stack region so it cannot overwrite the parent's move list.
        move_head[ply + 1] = move_head[ply]
        make_null_move(ply)
        local r = (depth >= 6) and 3 or 2
        local null_score = -negamax(-beta, -beta + 1, depth - 1 - r, ply + 1, false)
        unmake_null_move(ply)

        if stop_search then return 0 end
        if null_score >= beta then
            if null_score >= MATE_BOUND then null_score = beta end
            return null_score
        end
    end

    generate_moves(ply, false)
    score_moves(ply, tt_suggested_move)

    local head = move_head[ply]
    local tail = move_head[ply + 1] - 1

    local legal_moves = 0
    local best_score = -INFINITY
    local best_move = 0
    local original_alpha = alpha

    for i = head, tail do
        local best_idx = i
        local best_sc = score_stack[i]
        for j = i + 1, tail do
            if score_stack[j] > best_sc then
                best_sc = score_stack[j]
                best_idx = j
            end
        end
        if best_idx ~= i then
            local tm = move_stack[i]; move_stack[i] = move_stack[best_idx]; move_stack[best_idx] = tm
            local ts = score_stack[i]; score_stack[i] = score_stack[best_idx]; score_stack[best_idx] = ts
        end

        local m = move_stack[i]
        local to_sq = move_to(m)
        -- Classify BEFORE making the move: afterwards the destination holds our own piece.
        local is_quiet = board[to_sq] == EMPTY and move_promo(m) == 0 and move_flag(m) ~= FLAG_EP
        local mover = board[move_from(m)]

        if make_move(m, ply) then
            legal_moves = legal_moves + 1
            local score

            if legal_moves == 1 then
                score = -negamax(-beta, -alpha, depth - 1, ply + 1, true)
            else
                -- Late Move Reductions for late quiet moves that do not give check
                local reduction = 0
                if legal_moves > 3 and depth >= 3 and is_quiet and not in_chk and not in_check(side) then
                    reduction = 1
                    if legal_moves > 8 and depth >= 6 then reduction = 2 end
                end
                -- Principal Variation Search: null-window probe, re-search on fail-high
                score = -negamax(-alpha - 1, -alpha, depth - 1 - reduction, ply + 1, true)
                if score > alpha and reduction > 0 then
                    score = -negamax(-alpha - 1, -alpha, depth - 1, ply + 1, true)
                end
                if score > alpha and score < beta then
                    score = -negamax(-beta, -alpha, depth - 1, ply + 1, true)
                end
            end

            unmake_move(m, ply)
            if stop_search then return 0 end

            if score > best_score then
                best_score = score
                best_move = m
                if ply == 0 then root_best_move = m end
            end

            if score > alpha then
                alpha = score
                if alpha >= beta then
                    if is_quiet then
                        local k = killer_moves[ply]
                        if k[1] ~= m then
                            k[2] = k[1]
                            k[1] = m
                        end
                        local h = history_heuristic[mover]
                        local v = h[to_sq] + depth * depth
                        if v > 400000 then
                            -- Age the whole table so history never outranks killers
                            for p = 1, 12 do
                                local hp = history_heuristic[p]
                                for sq = 21, 98 do hp[sq] = floor(hp[sq] / 2) end
                            end
                            v = floor(v / 2)
                        end
                        h[to_sq] = v
                    end
                    break
                end
            end
        end
    end

    if legal_moves == 0 then
        if in_chk then return -MATE_SCORE + ply end
        return 0
    end

    local flag = TT_EXACT
    if best_score <= original_alpha then
        flag = TT_UPPER
    elseif best_score >= beta then
        flag = TT_LOWER
    end

    local store_score = best_score
    if store_score > MATE_BOUND then store_score = store_score + ply
    elseif store_score < -MATE_BOUND then store_score = store_score - ply end

    tt_key[tt_idx]   = zobrist_key
    tt_depth[tt_idx] = depth
    tt_score[tt_idx] = store_score
    tt_flag[tt_idx]  = flag
    tt_move[tt_idx]  = best_move

    return best_score
end


local function format_score(score)
    if abs(score) > MATE_BOUND then
        local mate_plies = MATE_SCORE - abs(score)
        local mate_moves = floor((mate_plies + 1) / 2)
        if score < 0 then mate_moves = -mate_moves end
        return "score mate " .. mate_moves
    end
    return "score cp " .. score
end

-- Iterative Deepening Search Root.
-- time_limit_ms: hard limit (nil = no limit). soft_ms: do not start a new
-- iteration after this much time (defaults to half the hard limit).
local function search_position(max_depth, time_limit_ms, soft_ms, no_bestmove, silent)
    nodes_searched = 0
    search_start_time = clock()
    search_stop_time = (time_limit_ms and time_limit_ms > 0)
        and (search_start_time + time_limit_ms / 1000)
        or math.huge
    stop_search = false

    max_depth = max_depth or 64
    if max_depth > MAX_SEARCH_PLY - 1 then max_depth = MAX_SEARCH_PLY - 1 end
    if not soft_ms and time_limit_ms then soft_ms = time_limit_ms * 0.5 end

    local best_move = 0
    local best_score = 0
    clear_heuristics()

    for current_depth = 1, max_depth do
        root_best_move = 0
        local score = negamax(-INFINITY, INFINITY, current_depth, 0, true)

        -- A partial iteration still yields a usable move if one was improved on.
        if stop_search then
            if root_best_move ~= 0 and current_depth > 1 then best_move = root_best_move end
            break
        end

        if root_best_move ~= 0 then
            best_move = root_best_move
            best_score = score
        end

        local elapsed = clock() - search_start_time
        local nps = floor(nodes_searched / (elapsed > 0 and elapsed or 0.001))

        if not silent then
            print(str_format("info depth %d %s nodes %d nps %d time %d pv %s",
                current_depth, format_score(best_score), nodes_searched, nps,
                floor(elapsed * 1000), move_to_uci(best_move)))
            io.flush()
        end

        if abs(best_score) > MATE_BOUND and current_depth >= (MATE_SCORE - abs(best_score)) then break end
        if soft_ms and elapsed * 1000 >= soft_ms then break end
        if stop_poll and stop_poll() then break end
    end

    if best_move == 0 then
        generate_moves(0, false)
        for i = move_head[0], move_head[1] - 1 do
            local m = move_stack[i]
            if make_move(m, 0) then
                unmake_move(m, 0)
                best_move = m
                break
            end
        end
    end

    if not no_bestmove then
        print("bestmove " .. move_to_uci(best_move))
        io.flush()
    end
    return best_move, best_score
end

-- ----------------------------------------------------------------------------
-- Perft Functions
-- ----------------------------------------------------------------------------
local function perft(depth, ply)
    if depth == 0 then return 1 end
    ply = ply or 0
    generate_moves(ply, false)

    local nodes = 0
    local head = move_head[ply]
    local tail = move_head[ply + 1] - 1

    for i = head, tail do
        local m = move_stack[i]
        if make_move(m, ply) then
            nodes = nodes + perft(depth - 1, ply + 1)
            unmake_move(m, ply)
        end
    end
    return nodes
end

local function perft_divide(depth)
    local t0 = clock()
    local total_nodes = 0
    local ply = 0
    generate_moves(ply, false)

    local head = move_head[ply]
    local tail = move_head[ply + 1] - 1

    for i = head, tail do
        local m = move_stack[i]
        if make_move(m, ply) then
            local count = perft(depth - 1, ply + 1)
            unmake_move(m, ply)
            print(str_format("%s: %d", move_to_uci(m), count))
            total_nodes = total_nodes + count
        end
    end

    local elapsed = clock() - t0
    print(str_format("\nPerft(%d) = %d nodes in %.3f sec (%.0f nps)", depth, total_nodes, elapsed, total_nodes / (elapsed > 0 and elapsed or 0.001)))
    return total_nodes
end

-- ----------------------------------------------------------------------------
-- UCI Protocol & Interactive Command-Line Interface
-- ----------------------------------------------------------------------------
local function parse_move(str)
    if #str < 4 then return nil end
    local from_coord = str_sub(str, 1, 2)
    local to_coord   = str_sub(str, 3, 4)
    local promo_char = str_sub(str, 5, 5)

    local from_sq = COORD_TO_SQ[from_coord]
    local to_sq   = COORD_TO_SQ[to_coord]
    if not from_sq or not to_sq then return nil end

    generate_moves(0, false)
    for i = move_head[0], move_head[1] - 1 do
        local m = move_stack[i]
        if move_from(m) == from_sq and move_to(m) == to_sq then
            if promo_char ~= "" then
                local pr = move_promo(m)
                if (promo_char == "q" and pr == W_QUEEN) or
                   (promo_char == "r" and pr == W_ROOK) or
                   (promo_char == "b" and pr == W_BISHOP) or
                   (promo_char == "n" and pr == W_KNIGHT) then
                    return m
                end
            else
                return m
            end
        end
    end
    return nil
end

-- Non-blocking stdin check, so "stop"/"quit" can interrupt a running search.
-- Requires LuaJIT's FFI; plain Lua 5.1 has no portable way to poll stdin, so
-- there the search can only end on its own limits (depth/time).
local input_available = nil
do
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi then
        pcall(function()
            if ffi.os == "Windows" then
                ffi.cdef([[
                    void* GetStdHandle(unsigned long n);
                    int PeekNamedPipe(void* h, void* buf, unsigned long sz, void* read,
                                      unsigned long* avail, void* left);
                ]])
                local h = ffi.C.GetStdHandle(4294967286) -- STD_INPUT_HANDLE (-10)
                local avail = ffi.new("unsigned long[1]")
                if ffi.C.PeekNamedPipe(h, nil, 0, nil, avail, nil) ~= 0 then
                    input_available = function()
                        if ffi.C.PeekNamedPipe(h, nil, 0, nil, avail, nil) == 0 then return true end -- pipe closed
                        return avail[0] > 0
                    end
                end
            else
                ffi.cdef([[
                    struct mf_pollfd { int fd; short events; short revents; };
                    int poll(struct mf_pollfd *fds, unsigned long nfds, int timeout);
                ]])
                local pfd = ffi.new("struct mf_pollfd[1]")
                pfd[0].fd = 0
                pfd[0].events = 1 -- POLLIN
                input_available = function()
                    return ffi.C.poll(pfd, 1, 0) > 0
                end
            end
        end)
    end
end

local pending_lines = {}
local quit_requested = false

local function read_line()
    if #pending_lines > 0 then return table.remove(pending_lines, 1) end
    return io.read("*line")
end

-- Called periodically from the search. Answers isready immediately, stops on
-- stop/quit, and queues anything else for after the search.
local poll_counter = 0
local function poll_input()
    poll_counter = poll_counter + 1
    if poll_counter % 8 ~= 0 then return false end
    while input_available() do
        local line = io.read("*line")
        if not line then quit_requested = true; return true end
        local cmd = line:match("^%s*(%S+)")
        if cmd == "stop" then return true
        elseif cmd == "quit" then quit_requested = true; return true
        elseif cmd == "isready" then print("readyok"); io.flush()
        elseif cmd then pending_lines[#pending_lines + 1] = line
        end
    end
    return false
end

local function uci_loop()
    reset_board()
    load_fen(START_FEN)
    -- Unbuffered stdin: buffered reads could swallow a "stop" before we poll for it.
    if io.stdin.setvbuf then pcall(io.stdin.setvbuf, io.stdin, "no") end

    while not quit_requested do
        local line = read_line()
        if not line then break end

        local tokens = {}
        for token in line:gmatch("%S+") do
            tokens[#tokens + 1] = token
        end

        local cmd = tokens[1]
        if cmd == "uci" then
            print("id name Moonfish 1.0")
            print("id author dunne67")
            print("uciok")

        elseif cmd == "isready" then
            print("readyok")

        elseif cmd == "ucinewgame" then
            clear_tt()
            clear_heuristics()
            reset_board()
            load_fen(START_FEN)

        elseif cmd == "position" then
            local idx = 2
            if tokens[2] == "startpos" then
                load_fen(START_FEN)
                idx = 3
            elseif tokens[2] == "fen" then
                local fen_parts = {}
                idx = 3
                while idx <= #tokens and tokens[idx] ~= "moves" do
                    fen_parts[#fen_parts + 1] = tokens[idx]
                    idx = idx + 1
                end
                load_fen(table.concat(fen_parts, " "))
            end

            if tokens[idx] == "moves" then
                idx = idx + 1
                while idx <= #tokens do
                    local m = parse_move(tokens[idx])
                    if not m or not make_move(m, 0) then
                        print("info string illegal move " .. tokens[idx] .. ", ignoring remaining moves")
                        break
                    end
                    rep_len = rep_len + 1
                    rep_keys[rep_len] = zobrist_key
                    idx = idx + 1
                end
            end

        elseif cmd == "go" then
            local depth = 64
            local movetime = nil
            local wtime, btime, winc, binc, movestogo
            local infinite = false

            local i = 2
            while i <= #tokens do
                if tokens[i] == "infinite" or tokens[i] == "ponder" then
                    infinite = true; i = i + 1
                elseif tokens[i] == "movestogo" then
                    movestogo = tonumber(tokens[i + 1]); i = i + 2
                elseif tokens[i] == "depth" then
                    depth = tonumber(tokens[i + 1])
                    i = i + 2
                elseif tokens[i] == "movetime" then
                    movetime = tonumber(tokens[i + 1])
                    i = i + 2
                elseif tokens[i] == "wtime" then
                    wtime = tonumber(tokens[i + 1]); i = i + 2
                elseif tokens[i] == "btime" then
                    btime = tonumber(tokens[i + 1]); i = i + 2
                elseif tokens[i] == "winc" then
                    winc = tonumber(tokens[i + 1]); i = i + 2
                elseif tokens[i] == "binc" then
                    binc = tonumber(tokens[i + 1]); i = i + 2
                else
                    i = i + 1
                end
            end

            local hard, soft
            local my_time = (side == WHITE) and wtime or btime
            if infinite then
                hard, soft = nil, nil
            elseif movetime then
                hard = movetime
                soft = movetime -- use the full budget; the hard limit stops mid-iteration
            elseif my_time then
                local my_inc = ((side == WHITE) and winc or binc) or 0
                local mtg = movestogo or 30
                if mtg < 1 then mtg = 1 end
                local overhead = 30
                soft = my_time / (mtg + 2) + my_inc * 0.75
                hard = soft * 3
                local cap = my_time * 0.4 - overhead
                if hard > cap then hard = cap end
                if hard < 10 then hard = 10 end
                if soft > hard then soft = hard end
            end

            if infinite and not input_available then
                print("info string stop is unsupported without LuaJIT; searching to depth " .. min(depth, MAX_SEARCH_PLY - 1))
            end
            stop_poll = input_available and poll_input or nil
            local best = search_position(depth, hard, soft, true)
            stop_poll = nil
            print("bestmove " .. move_to_uci(best))

        elseif cmd == "perft" then
            local d = tonumber(tokens[2]) or 1
            perft_divide(d)

        elseif cmd == "eval" then
            print("Static Eval: " .. evaluate() .. " cp (Perspective of " .. (side == WHITE and "White" or "Black") .. ")")

        elseif cmd == "d" or cmd == "print" then
            print_board()

        elseif cmd == "quit" then
            break
        end

        io.flush()
    end
end

-- Export API
Moonfish.load_fen = load_fen
Moonfish.reset_board = reset_board
Moonfish.perft = perft
Moonfish.perft_divide = perft_divide
Moonfish.evaluate = evaluate
Moonfish.search_position = search_position
Moonfish.make_move = make_move
Moonfish.unmake_move = unmake_move
Moonfish.uci_loop = uci_loop
Moonfish.print_board = print_board
Moonfish.clear_tt = clear_tt
Moonfish.move_to_uci = move_to_uci

-- Execute UCI loop if run directly from command line
if pcall(debug.getlocal, 4, 1) == false then
    uci_loop()
end

return Moonfish
