-- Reversi evaluation module using NegaScout with 1D board and Zobrist hashing
-- Switches to exhaustive search (NegaAlpha) when empty cells <= threshold
-- Uses multiple weight tables for different game stages

local M = {}

local BOOK_THRESHOLD = 12
local ENDGAME_THRESHOLD = 12   -- Switch to exhaustive search when empty cells <= this
local SEARCH_DEPTH = 6         -- Depth for midgame NegaScout search

-- Opening book
local opening_book = nil
local BOOK_FILE = nil  -- Will be set from Vim

-- Load opening book
local function load_opening_book()
  if opening_book then
    return true
  end
  
  if not BOOK_FILE then
    -- Try to find book.lua in the same directory as this script
    local info = debug.getinfo(1, "S")
    if info and info.source then
      local script_path = info.source:match("^@?(.*/)")
      if script_path then
        BOOK_FILE = script_path .. "book.lua"
      end
    end
  end

  if BOOK_FILE then
    local success, book = pcall(dofile, BOOK_FILE)
    if success and type(book) == "table" then
      opening_book = book
      return true
    end
  end
  
  -- Book not available
  opening_book = {}
  return false
end

-- Convert 1D board to string key for book lookup
local function board_to_book_key(board, discs)
  local key = {}
  for i = 1, 64 do
    if board[i] == discs.empty then
      key[i] = '0'
    elseif board[i] == discs.cpu then
      key[i] = '1'
    else
      key[i] = '2'
    end
  end
  return table.concat(key)
end

-- Convert move notation (e.g., "f5") to coordinates
local function parse_book_move(move_str)
  local col = string.byte(move_str, 1) - string.byte('a')  -- a=0, b=1, ..., h=7
  local row = tonumber(move_str:sub(2)) - 1  -- 1=0, 2=1, ..., 8=7
  return row, col
end

-- Find matching move from book moves in available moves list
local function find_book_move_in_moves(book_move, moves)
  local row, col = parse_book_move(book_move)
  for i, move in ipairs(moves) do
    if move.row == row and move.col == col then
      -- return i
      return move
    end
  end
  return nil
end

-- Bitwise operations compatibility layer
local bit_xor
if bit32 then
  -- Lua 5.2+
  bit_xor = bit32.bxor
elseif bit then
  -- LuaJIT
  bit_xor = bit.bxor
else
  -- Fallback for Lua 5.1
  bit_xor = function(a, b)
    local p, c = 1, 0
    while a > 0 or b > 0 do
      local ra, rb = a % 2, b % 2
      if ra ~= rb then c = c + p end
      a, b, p = (a - ra) / 2, (b - rb) / 2, p * 2
    end
    return c
  end
end

-- 16 game symmetric INTEGER weights
local WEIGHTS_16 = {
    9188, -2397,  207, -287, -287,  207, -2397, 9188,
    -2397, -5560, -1314, -999, -999, -1314, -5560, -2397,
     207, -1314, -457, -378, -378, -457, -1314,  207,
    -287, -999, -378, -374, -374, -378, -999, -287,
    -287, -999, -378, -374, -374, -378, -999, -287,
     207, -1314, -457, -378, -378, -457, -1314,  207,
    -2397, -5560, -1314, -999, -999, -1314, -5560, -2397,
    9188, -2397,  207, -287, -287,  207, -2397, 9188,
}

-- 24 game symmetric INTEGER weights
local WEIGHTS_24 = {
    9628, -1524,  212,   26,   26,  212, -1524, 9628,
    -1524, -5020, -975, -764, -764, -975, -5020, -1524,
     212, -975, -371, -310, -310, -371, -975,  212,
      26, -764, -310, -306, -306, -310, -764,   26,
      26, -764, -310, -306, -306, -310, -764,   26,
     212, -975, -371, -310, -310, -371, -975,  212,
    -1524, -5020, -975, -764, -764, -975, -5020, -1524,
    9628, -1524,  212,   26,   26,  212, -1524, 9628,
}

-- 32 game symmetric INTEGER weights
local WEIGHTS_32 = {
    7484, -539,   73,   34,   34,   73, -539, 7484,
    -539, -3536, -730, -597, -597, -730, -3536, -539,
      73, -730, -335, -289, -289, -335, -730,   73,
      34, -597, -289, -223, -223, -289, -597,   34,
      34, -597, -289, -223, -223, -289, -597,   34,
      73, -730, -335, -289, -289, -335, -730,   73,
    -539, -3536, -730, -597, -597, -730, -3536, -539,
    7484, -539,   73,   34,   34,   73, -539, 7484,
}

-- 40 game symmetric INTEGER weights
local WEIGHTS_40 = {
    5145,  -61,   20,   40,   40,   20,  -61, 5145,
     -61, -1923, -583, -450, -450, -583, -1923,  -61,
      20, -583, -337, -214, -214, -337, -583,   20,
      40, -450, -214, -140, -140, -214, -450,   40,
      40, -450, -214, -140, -140, -214, -450,   40,
      20, -583, -337, -214, -214, -337, -583,   20,
     -61, -1923, -583, -450, -450, -583, -1923,  -61,
    5145,  -61,   20,   40,   40,   20,  -61, 5145,
}

-- 48 game symmetric INTEGER weights
local WEIGHTS_48 = {
    3539,  235,   17,   37,   37,   17,  235, 3539,
     235, -882, -465, -257, -257, -465, -882,  235,
      17, -465, -365, -127, -127, -365, -465,   17,
      37, -257, -127, -105, -105, -127, -257,   37,
      37, -257, -127, -105, -105, -127, -257,   37,
      17, -465, -365, -127, -127, -365, -465,   17,
     235, -882, -465, -257, -257, -465, -882,  235,
    3539,  235,   17,   37,   37,   17,  235, 3539,
}

-- 56 game symmetric INTEGER weights
local WEIGHTS_56 = {
    2379,  475,   36,   38,   38,   36,  475, 2379,
     475, -277, -316,  -82,  -82, -316, -277,  475,
      36, -316, -318,   14,   14, -318, -316,   36,
      38,  -82,   14,    5,    5,   14,  -82,   38,
      38,  -82,   14,    5,    5,   14,  -82,   38,
      36, -316, -318,   14,   14, -318, -316,   36,
     475, -277, -316,  -82,  -82, -316, -277,  475,
    2379,  475,   36,   38,   38,   36,  475, 2379,
}

-- 64 game symmetric INTEGER weights
local WEIGHTS_64 = {
    1332,  557,   43,   94,   94,   43,  557, 1332,
     557,   67,  -21,   99,   99,  -21,   67,  557,
      43,  -21,  -35,  270,  270,  -35,  -21,   43,
      94,   99,  270,  229,  229,  270,   99,   94,
      94,   99,  270,  229,  229,  270,   99,   94,
      43,  -21,  -35,  270,  270,  -35,  -21,   43,
     557,   67,  -21,   99,   99,  -21,   67,  557,
    1332,  557,   43,   94,   94,   43,  557, 1332,
}

-- 8 game symmetric INTEGER weights
local WEIGHTS_8 = {
       0,    0,    0,    0,    0,    0,    0,    0,
       0,    0, -1878, -582, -582, -1878,    0,    0,
       0, -1878, -152, -139, -139, -152, -1878,    0,
       0, -582, -139, -254, -254, -139, -582,    0,
       0, -582, -139, -254, -254, -139, -582,    0,
       0, -1878, -152, -139, -139, -152, -1878,    0,
       0,    0, -1878, -582, -582, -1878,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,
}

--
-- local WEIGHTS_16 = {
--     9200, -2393,  204, -284, -284,  204, -2393, 9200,
--     -2393, -5561, -1316, -1000, -1000, -1316, -5561, -2393,
--      204, -1316, -457, -378, -378, -457, -1316,  204,
--     -284, -1000, -378, -375, -375, -378, -1000, -284,
--     -284, -1000, -378, -375, -375, -378, -1000, -284,
--      204, -1316, -457, -378, -378, -457, -1316,  204,
--     -2393, -5561, -1316, -1000, -1000, -1316, -5561, -2393,
--     9200, -2393,  204, -284, -284,  204, -2393, 9200,
-- }
--
-- local WEIGHTS_24 = {
--     9632, -1525,  209,   25,   25,  209, -1525, 9632,
--     -1525, -5019, -975, -764, -764, -975, -5019, -1525,
--      209, -975, -371, -311, -311, -371, -975,  209,
--       25, -764, -311, -306, -306, -311, -764,   25,
--       25, -764, -311, -306, -306, -311, -764,   25,
--      209, -975, -371, -311, -311, -371, -975,  209,
--     -1525, -5019, -975, -764, -764, -975, -5019, -1525,
--     9632, -1525,  209,   25,   25,  209, -1525, 9632,
-- }
--
-- local WEIGHTS_32 = {
--     7490, -538,   72,   34,   34,   72, -538, 7490,
--     -538, -3536, -731, -596, -596, -731, -3536, -538,
--       72, -731, -334, -290, -290, -334, -731,   72,
--       34, -596, -290, -222, -222, -290, -596,   34,
--       34, -596, -290, -222, -222, -290, -596,   34,
--       72, -731, -334, -290, -290, -334, -731,   72,
--     -538, -3536, -731, -596, -596, -731, -3536, -538,
--     7490, -538,   72,   34,   34,   72, -538, 7490,
-- }
--
-- local WEIGHTS_40 = {
--     5148,  -61,   20,   39,   39,   20,  -61, 5148,
--      -61, -1927, -583, -450, -450, -583, -1927,  -61,
--       20, -583, -337, -214, -214, -337, -583,   20,
--       39, -450, -214, -139, -139, -214, -450,   39,
--       39, -450, -214, -139, -139, -214, -450,   39,
--       20, -583, -337, -214, -214, -337, -583,   20,
--      -61, -1927, -583, -450, -450, -583, -1927,  -61,
--     5148,  -61,   20,   39,   39,   20,  -61, 5148,
-- }
--
-- local WEIGHTS_48 = {
--     3539,  235,   16,   38,   38,   16,  235, 3539,
--      235, -882, -465, -257, -257, -465, -882,  235,
--       16, -465, -365, -127, -127, -365, -465,   16,
--       38, -257, -127, -105, -105, -127, -257,   38,
--       38, -257, -127, -105, -105, -127, -257,   38,
--       16, -465, -365, -127, -127, -365, -465,   16,
--      235, -882, -465, -257, -257, -465, -882,  235,
--     3539,  235,   16,   38,   38,   16,  235, 3539,
-- }
--
-- local WEIGHTS_56 = {
--     2378,  475,   36,   38,   38,   36,  475, 2378,
--      475, -277, -316,  -82,  -82, -316, -277,  475,
--       36, -316, -318,   14,   14, -318, -316,   36,
--       38,  -82,   14,    6,    6,   14,  -82,   38,
--       38,  -82,   14,    6,    6,   14,  -82,   38,
--       36, -316, -318,   14,   14, -318, -316,   36,
--      475, -277, -316,  -82,  -82, -316, -277,  475,
--     2378,  475,   36,   38,   38,   36,  475, 2378,
-- }
--
-- local WEIGHTS_64 = {
--     1332,  557,   44,   94,   94,   44,  557, 1332,
--      557,   67,  -22,   99,   99,  -22,   67,  557,
--       44,  -22,  -35,  270,  270,  -35,  -22,   44,
--       94,   99,  270,  231,  231,  270,   99,   94,
--       94,   99,  270,  231,  231,  270,   99,   94,
--       44,  -22,  -35,  270,  270,  -35,  -22,   44,
--      557,   67,  -22,   99,   99,  -22,   67,  557,
--     1332,  557,   44,   94,   94,   44,  557, 1332,
-- }
--
-- local WEIGHTS_8 = {
--        0,    0,    0,    0,    0,    0,    0,    0,
--        0, -8064, -2133, -989, -989, -2133, -8064,    0,
--        0, -2133, -172,    2,    2, -172, -2133,    0,
--        0, -989,    2, -292, -292,    2, -989,    0,
--        0, -989,    2, -292, -292,    2, -989,    0,
--        0, -2133, -172,    2,    2, -172, -2133,    0,
--        0, -8064, -2133, -989, -989, -2133, -8064,    0,
--        0,    0,    0,    0,    0,    0,    0,    0,
-- }

-- Zobrist hashing tables
local zobrist = {
  keys = {},  -- [position][disc_type] -> random number
  initialized = false
}

-- Transposition table
local transposition_table = {}
local TT_SIZE = 65536  -- Power of 2 for fast modulo
local TT_EXACT = 0
local TT_ALPHA = 1
local TT_BETA = 2

-- Initialize Zobrist hash keys
local function init_zobrist()
  if zobrist.initialized then return end
  
  math.randomseed(12345)  -- Fixed seed for consistency
  
  for pos = 0, 63 do
    zobrist.keys[pos] = {}
    for disc = 0, 2 do  -- 0=empty, 1=cpu, 2=user
      -- Generate random 32-bit integers (Lua 5.1 compatible)
      local high = math.random(0, 65535)
      local low = math.random(0, 65535)
      zobrist.keys[pos][disc] = high * 65536 + low
    end
  end
  
  zobrist.initialized = true
end

-- Convert disc value to zobrist index (0, 1, 2)
local function disc_to_index(disc, discs)
  if disc == discs.empty then return 0
  elseif disc == discs.cpu then return 1
  else return 2 end
end

-- Calculate Zobrist hash for a board
local function calculate_hash(board, discs)
  local hash = 0
  for pos = 0, 63 do
    local disc = board[pos + 1]
    local idx = disc_to_index(disc, discs)
    hash = bit_xor(hash, zobrist.keys[pos][idx])
  end
  return hash
end

-- Convert 2D board to 1D
local function convert_to_1d(board_2d)
  local board_1d = {}
  for r = 1, 8 do
    for c = 1, 8 do
      board_1d[(r-1) * 8 + c] = board_2d[r][c]
    end
  end
  return board_1d
end

-- Copy 1D board
local function copy_board(board)
  local new_board = {}
  for i = 1, 64 do
    new_board[i] = board[i]
  end
  return new_board
end

-- Count empty cells
local function count_empty_cells(board, discs)
  local count = 0
  for i = 1, 64 do
    if board[i] == discs.empty then
      count = count + 1
    end
  end
  return count
end

-- Count discs for final scoring
local function count_discs(board, discs)
  local cpu_count = 0
  local user_count = 0
  for i = 1, 64 do
    if board[i] == discs.cpu then
      cpu_count = cpu_count + 1
    elseif board[i] == discs.user then
      user_count = user_count + 1
    end
  end
  return cpu_count, user_count
end

-- Select appropriate weight table based on empty cell count
local function get_weights(empty_count)
  if empty_count >= 56 then
    return WEIGHTS_8
  elseif empty_count >= 48 then
    return WEIGHTS_16
  elseif empty_count >= 40 then
    return WEIGHTS_24
  elseif empty_count >= 32 then
    return WEIGHTS_32
  elseif empty_count >= 24 then
    return WEIGHTS_40
  elseif empty_count >= 16 then
    return WEIGHTS_48
  elseif empty_count >= 8 then
    return WEIGHTS_56
  else
    return WEIGHTS_64
  end
end

-- Evaluate board from CPU's perspective
local function evaluate_board(board, discs, empty_count)
  local weights = get_weights(empty_count)
  local score = 0
  for pos = 1, 64 do
    local cell = board[pos]
    if cell == discs.cpu then
      score = score + weights[pos]
    elseif cell == discs.user then
      score = score - weights[pos]
    end
  end
  return score
end

-- Convert 1D position to 2D coordinates
local function pos_to_coords(pos)
  return math.floor(pos / 8), pos % 8
end

-- Convert 2D coordinates to 1D position
local function coords_to_pos(row, col)
  return row * 8 + col
end

-- Apply a move to the board and update hash
local function apply_move(board, hash, move, disc, discs)
  local new_board = copy_board(board)
  local new_hash = hash
  local pos = coords_to_pos(move.row, move.col)
  local disc_idx = disc_to_index(disc, discs)
  local empty_idx = disc_to_index(discs.empty, discs)
  
  -- Place the disc
  new_board[pos + 1] = disc
  new_hash = bit_xor(new_hash, zobrist.keys[pos][empty_idx])
  new_hash = bit_xor(new_hash, zobrist.keys[pos][disc_idx])
  
  -- Flip opponent discs
  for _, flip in ipairs(move.flips) do
    local flip_pos = coords_to_pos(flip.r, flip.c)
    local old_disc = new_board[flip_pos + 1]
    local old_idx = disc_to_index(old_disc, discs)
    
    new_board[flip_pos + 1] = disc
    new_hash = bit_xor(new_hash, zobrist.keys[flip_pos][old_idx])
    new_hash = bit_xor(new_hash, zobrist.keys[flip_pos][disc_idx])
  end
  
  return new_board, new_hash
end

-- Get opponent disc
local function get_opponent(disc, discs)
  return disc == discs.cpu and discs.user or discs.cpu
end

-- Check if a position is valid
local function is_valid_position(row, col)
  return row >= 0 and row < 8 and col >= 0 and col < 8
end

-- Get all valid moves for a player (using 1D board)
local function get_valid_moves(board, disc, discs)
  local moves = {}
  local opponent = get_opponent(disc, discs)
  
  local directions = {
    {-1, -1}, {-1, 0}, {-1, 1},
    {0, -1},           {0, 1},
    {1, -1},  {1, 0},  {1, 1}
  }
  
  for pos = 0, 63 do
    if board[pos + 1] == discs.empty then
      local row, col = pos_to_coords(pos)
      local flips = {}
      
      for _, dir in ipairs(directions) do
        local dr, dc = dir[1], dir[2]
        local r, c = row + dr, col + dc
        local temp_flips = {}
        
        while is_valid_position(r, c) and board[coords_to_pos(r, c) + 1] == opponent do
          table.insert(temp_flips, {r = r, c = c})
          r = r + dr
          c = c + dc
        end
        
        if is_valid_position(r, c) and board[coords_to_pos(r, c) + 1] == disc and #temp_flips > 0 then
          for _, p in ipairs(temp_flips) do
            table.insert(flips, p)
          end
        end
      end
      
      if #flips > 0 then
        table.insert(moves, {row = row, col = col, flips = flips})
      end
    end
  end
  
  return moves
end

-- Store position in transposition table
local function tt_store(hash, depth, score, flag)
  local index = (hash % TT_SIZE) + 1
  transposition_table[index] = {
    hash = hash,
    depth = depth,
    score = score,
    flag = flag
  }
end

-- Probe transposition table
local function tt_probe(hash, depth, alpha, beta)
  local index = (hash % TT_SIZE) + 1
  local entry = transposition_table[index]
  
  if entry and entry.hash == hash and entry.depth >= depth then
    if entry.flag == TT_EXACT then
      return entry.score, true
    elseif entry.flag == TT_ALPHA and entry.score <= alpha then
      return alpha, true
    elseif entry.flag == TT_BETA and entry.score >= beta then
      return beta, true
    end
  end
  
  return 0, false
end

-- NegaAlpha algorithm for exhaustive endgame search
-- Searches to the end of the game, counting actual disc differences
local function negaalpha_exhaustive(board, hash, alpha, beta, disc, discs, empty_count)
  -- Check transposition table (use max depth for endgame)
  local tt_score, tt_hit = tt_probe(hash, 999, alpha, beta)
  if tt_hit then
    return tt_score
  end
  
  local moves = get_valid_moves(board, disc, discs)
  
  if #moves == 0 then
    local opponent = get_opponent(disc, discs)
    local opponent_moves = get_valid_moves(board, opponent, discs)
    
    if #opponent_moves == 0 then
      -- Game over - count final disc difference
      local cpu_count, user_count = count_discs(board, discs)
      local diff = cpu_count - user_count
      
      -- Add bonus for winning/losing to encourage decisive victories
      if diff > 0 then
        diff = diff + 64  -- Win bonus
      elseif diff < 0 then
        diff = diff - 64  -- Loss penalty
      end
      
      local score = disc == discs.cpu and diff or -diff
      tt_store(hash, 999, score, TT_EXACT)
      return score
    else
      -- Pass to opponent
      return -negaalpha_exhaustive(board, hash, -beta, -alpha, opponent, discs, empty_count)
    end
  end
  
  local best_score = -math.huge
  local original_alpha = alpha
  
  for _, move in ipairs(moves) do
    local new_board, new_hash = apply_move(board, hash, move, disc, discs)
    local score = -negaalpha_exhaustive(new_board, new_hash, -beta, -alpha, get_opponent(disc, discs), discs, empty_count - 1)
    
    best_score = math.max(best_score, score)
    alpha = math.max(alpha, score)
    
    if alpha >= beta then
      break  -- Beta cutoff
    end
  end
  
  -- Store in transposition table
  local flag
  if best_score <= original_alpha then
    flag = TT_ALPHA
  elseif best_score >= beta then
    flag = TT_BETA
  else
    flag = TT_EXACT
  end
  tt_store(hash, 999, best_score, flag)
  
  return best_score
end

-- NegaScout algorithm with Zobrist hashing for midgame
local function negascout(board, hash, depth, alpha, beta, disc, discs, empty_count)
  -- Check transposition table
  local tt_score, tt_hit = tt_probe(hash, depth, alpha, beta)
  if tt_hit then
    return tt_score
  end
  
  if depth == 0 then
    local score = evaluate_board(board, discs, empty_count)
    score = disc == discs.cpu and score or -score
    tt_store(hash, depth, score, TT_EXACT)
    return score
  end
  
  local moves = get_valid_moves(board, disc, discs)
  
  if #moves == 0 then
    local opponent = get_opponent(disc, discs)
    local opponent_moves = get_valid_moves(board, opponent, discs)
    
    if #opponent_moves == 0 then
      local score = evaluate_board(board, discs, empty_count)
      score = disc == discs.cpu and score or -score
      tt_store(hash, depth, score, TT_EXACT)
      return score
    else
      return -negascout(board, hash, depth - 1, -beta, -alpha, opponent, discs, empty_count)
    end
  end
  
  local best_score = -math.huge
  local original_alpha = alpha
  
  for i, move in ipairs(moves) do
    local new_board, new_hash = apply_move(board, hash, move, disc, discs)
    local score
    
    if i == 1 then
      score = -negascout(new_board, new_hash, depth - 1, -beta, -alpha, get_opponent(disc, discs), discs, empty_count - 1)
    else
      score = -negascout(new_board, new_hash, depth - 1, -alpha - 1, -alpha, get_opponent(disc, discs), discs, empty_count - 1)
      
      if alpha < score and score < beta then
        score = -negascout(new_board, new_hash, depth - 1, -beta, -score, get_opponent(disc, discs), discs, empty_count - 1)
      end
    end
    
    best_score = math.max(best_score, score)
    alpha = math.max(alpha, score)
    
    if alpha >= beta then
      break
    end
  end
  
  -- Store in transposition table
  local flag
  if best_score <= original_alpha then
    flag = TT_ALPHA
  elseif best_score >= beta then
    flag = TT_BETA
  else
    flag = TT_EXACT
  end
  tt_store(hash, depth, best_score, flag)
  
  return best_score
end

-- Find the best move using NegaScout (midgame) or exhaustive search (endgame)
function M.best_move(board_2d, moves, discs)
  if #moves == 0 then
    return 0, 0
  end
  
  -- Try to use opening book first
  local board = convert_to_1d(board_2d)
  local empty_count = count_empty_cells(board, discs)
  local valid_moves = {}
  if empty_count >= BOOK_THRESHOLD then
    load_opening_book()
    
    local book_key = board_to_book_key(board, discs)
    
    if opening_book and opening_book[book_key] then
      local book_moves = opening_book[book_key]
      -- Try each book move in order until we find one that's valid
      for _, book_move in ipairs(book_moves) do
        local move_idx = find_book_move_in_moves(book_move, moves)
        if move_idx then
          valid_moves[#valid_moves + 1] = move_idx
          -- Found a book move that's valid
          -- return move_idx - 1, 9999  -- Return high score to indicate book move

        end
      end
    end
  end
  
  -- No book move available, use normal search
  -- Initialize Zobrist hashing
  init_zobrist()
  
  local hash = calculate_hash(board, discs)

  if #valid_moves ~= 0 then
    moves = valid_moves
  end
  
  local use_exhaustive = empty_count <= ENDGAME_THRESHOLD
  
  local best_idx = 0
  local best_score = -math.huge
  local alpha = -math.huge
  local beta = math.huge
  
  if use_exhaustive then
    -- Endgame: Exhaustive search to find perfect play
    for i, move in ipairs(moves) do
      local new_board, new_hash = apply_move(board, hash, move, discs.cpu, discs)
      local score = -negaalpha_exhaustive(new_board, new_hash, -beta, -alpha, discs.user, discs, empty_count - 1)
      
      if score > best_score then
        best_score = score
        best_idx = i - 1
      end
      
      alpha = math.max(alpha, score)
    end
  else
    -- Midgame: NegaScout with depth limit
    for i, move in ipairs(moves) do
      local new_board, new_hash = apply_move(board, hash, move, discs.cpu, discs)
      local score
      
      if i == 1 then
        score = -negascout(new_board, new_hash, SEARCH_DEPTH - 1, -beta, -alpha, discs.user, discs, empty_count - 1)
      else
        score = -negascout(new_board, new_hash, SEARCH_DEPTH - 1, -alpha - 1, -alpha, discs.user, discs, empty_count - 1)
        
        if alpha < score and score < beta then
          score = -negascout(new_board, new_hash, SEARCH_DEPTH - 1, -beta, -score, discs.user, discs, empty_count - 1)
        end
      end
      
      if score > best_score then
        best_score = score
        best_idx = i - 1
      end
      
      alpha = math.max(alpha, score)
    end
  end
  
  return best_idx, best_score
end

return M
