" Reversi evaluation module

" Check for Lua support
let s:has_lua = has('nvim') || has('lua')

if s:has_lua
  let s:lua_module_path = expand('<sfile>:p:h') . '/eval.lua'
  
  lua << EOF
  -- Compatibility layer for Neovim vs Vim
  local eval_fn = vim.api and vim.api.nvim_eval or vim.eval
  local cmd_fn = vim.api and vim.api.nvim_command or vim.command
  
  local module_path = eval_fn('s:lua_module_path')
  _G.reversi_eval_module = dofile(module_path)
  _G.reversi_eval_fn = eval_fn
  _G.reversi_cmd_fn = cmd_fn
EOF
endif

function! reversi#eval#get_engine_type() abort
  return s:has_lua ? 'Lua (Nega-Scout)' : 'Vim script (Simple)'
endfunction

let s:weights = [
      \ [ 2714,  147,   69,  -18,  -18,   69,  147, 2714 ],
      \ [  147, -577, -186, -153, -153, -186, -577,  147 ],
      \ [   69, -186, -379, -122, -122, -379, -186,   69 ],
      \ [  -18, -153, -122, -169, -169, -122, -153,  -18 ],
      \ [  -18, -153, -122, -169, -169, -122, -153,  -18 ],
      \ [   69, -186, -379, -122, -122, -379, -186,   69 ],
      \ [  147, -577, -186, -153, -153, -186, -577,  147 ],
      \ [ 2714,  147,   69,  -18,  -18,   69,  147, 2714 ],
      \ ]

function! s:copy_board(board) abort
  let new_board = []
  for r in range(8)
    let new_board = add(new_board, copy(a:board[r]))
  endfor
  return new_board
endfunction

function! s:score_board(board, discs) abort
  let score = 0
  for r in range(8)
    for c in range(8)
      let cell = a:board[r][c]
      if cell == a:discs.cpu
        let score += s:weights[r][c]
      elseif cell == a:discs.user
        let score -= s:weights[r][c]
      endif
    endfor
  endfor
  return score
endfunction

function! reversi#eval#best_move(board, moves, discs) abort
  if len(a:moves) == 0
    return [v:null, 0]
  endif

  if s:has_lua
    let s:_board = a:board
    let s:_moves = a:moves
    let s:_discs = a:discs
    
    lua << EOF
    local board = _G.reversi_eval_fn('s:_board')
    local moves = _G.reversi_eval_fn('s:_moves')
    local discs = _G.reversi_eval_fn('s:_discs')
    local idx, score = _G.reversi_eval_module.best_move(board, moves, discs)
    _G.reversi_cmd_fn(string.format('let s:_result = [%d, %d]', idx, score))
EOF
    
    let chosen = a:moves[s:_result[0]]
    let score = s:_result[1]
    return [chosen, score]
  else
    let best_score = v:null
    let best_moves = []

    for move in a:moves
      let simulated = s:copy_board(a:board)
      let simulated[move.row][move.col] = a:discs.cpu
      for pos in move.flips
        let simulated[pos.r][pos.c] = a:discs.cpu
      endfor

      let score = s:score_board(simulated, a:discs)

      if best_score is v:null || score > best_score
        let best_score = score
        let best_moves = [move]
      elseif score == best_score
        call add(best_moves, move)
      endif
    endfor

    let chosen = best_moves[str2nr(reltimestr(reltime())) % len(best_moves)]
    return [chosen, best_score]
  endif
endfunction
