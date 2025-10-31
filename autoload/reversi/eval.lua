-- Reversi evaluation module using NegaScout with 1D board and Zobrist hashing
-- Switches to exhaustive search (NegaAlpha) when empty cells <= threshold
-- Uses multiple weight tables for different game stages

local M = {}

local ENDGAME_THRESHOLD = 12   -- Switch to exhaustive search when empty cells <= this
local SEARCH_DEPTH = 7         -- Depth for midgame NegaScout search

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

local WEIGHTS_16 = {
    9173, -2397,  209, -290, -290,  209, -2397, 9173,
    -2397, -5556, -1315, -999, -999, -1315, -5556, -2397,
     209, -1315, -457, -378, -378, -457, -1315,  209,
    -290, -999, -378, -373, -373, -378, -999, -290,
    -290, -999, -378, -373, -373, -378, -999, -290,
     209, -1315, -457, -378, -378, -457, -1315,  209,
    -2397, -5556, -1315, -999, -999, -1315, -5556, -2397,
    9173, -2397,  209, -290, -290,  209, -2397, 9173,
}

local WEIGHTS_32 = {
    8223, -829,  120,   36,   36,  120, -829, 8223,
    -829, -4142, -811, -654, -654, -811, -4142, -829,
     120, -811, -354, -294, -294, -354, -811,  120,
      36, -654, -294, -257, -257, -294, -654,   36,
      36, -654, -294, -257, -257, -294, -654,   36,
     120, -811, -354, -294, -294, -354, -811,  120,
    -829, -4142, -811, -654, -654, -811, -4142, -829,
    8223, -829,  120,   36,   36,  120, -829, 8223,
}

local WEIGHTS_48 = {
    4036,  127,   12,   30,   30,   12,  127, 4036,
     127, -1209, -491, -331, -331, -491, -1209,  127,
      12, -491, -356, -173, -173, -356, -491,   12,
      30, -331, -173, -136, -136, -173, -331,   30,
      30, -331, -173, -136, -136, -173, -331,   30,
      12, -491, -356, -173, -173, -356, -491,   12,
     127, -1209, -491, -331, -331, -491, -1209,  127,
    4036,  127,   12,   30,   30,   12,  127, 4036,
}

local WEIGHTS_64 = {
    1854,  505,   44,   59,   59,   44,  505, 1854,
     505,  -33, -154,    8,    8, -154,  -33,  505,
      44, -154, -239,  133,  133, -239, -154,   44,
      59,    8,  133,  112,  112,  133,    8,   59,
      59,    8,  133,  112,  112,  133,    8,   59,
      44, -154, -239,  133,  133, -239, -154,   44,
     505,  -33, -154,    8,    8, -154,  -33,  505,
    1854,  505,   44,   59,   59,   44,  505, 1854,
}

local WEIGHTS_8 = {
       0,    0,    0,    0,    0,    0,    0,    0,
       0,  -70, -173,   35,   35, -173,  -70,    0,
       0, -173, -108, -114, -114, -108, -173,    0,
       0,   35, -114,   34,   34, -114,   35,    0,
       0,   35, -114,   34,   34, -114,   35,    0,
       0, -173, -108, -114, -114, -108, -173,    0,
       0,  -70, -173,   35,   35, -173,  -70,    0,
       0,    0,    0,    0,    0,    0,    0,    0,
}

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
  -- elseif empty_count >= 44 then
  --   return WEIGHTS_20
  -- elseif empty_count >= 40 then
  --   return WEIGHTS_24
  -- elseif empty_count >= 36 then
  --   return WEIGHTS_28
  elseif empty_count >= 32 then
    return WEIGHTS_32
  -- elseif empty_count >= 28 then
  --   return WEIGHTS_36
  -- elseif empty_count >= 24 then
  --   return WEIGHTS_40
  -- elseif empty_count >= 20 then
  --   return WEIGHTS_44
  elseif empty_count >= 16 then
    return WEIGHTS_48
  else
    return WEIGHTS_64
    -- return WEIGHTS_52
  end
  -- if empty_count > OPENING_THRESHOLD then
  --   return weights_opening
  -- elseif empty_count > ENDGAME_THRESHOLD then
  --   return weights_middlegame
  -- else
  --   return weights_endgame
  -- end
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
  
  -- Initialize Zobrist hashing
  init_zobrist()
  
  -- Convert to 1D board
  local board = convert_to_1d(board_2d)
  local hash = calculate_hash(board, discs)
  
  -- Count empty cells to determine search strategy
  local empty_count = count_empty_cells(board, discs)
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
