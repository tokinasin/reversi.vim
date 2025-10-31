" Reversi game for Vim

let s:Disc = {
      \ 'empty': 0,
      \ 'user': 1,
      \ 'cpu': 2,
      \ }

let s:state = {
      \ 'buf': -1,
      \ 'board': [],
      \ 'discs': s:Disc,
      \ 'turn': 'user',
      \ 'status_message': '',
      \ 'game_over': 0,
      \ 'highlights_defined': 0,
      \ 'win': -1,
      \ 'last_cursor': {'row': 3, 'col': 3},
      \ 'prop_types_defined': 0,
      \ 'ns_id': -1,
      \ 'first_player': 'user',
      \ }

let s:directions = [
      \ [-1, -1], [-1, 0], [-1, 1],
      \ [ 0, -1],          [ 0, 1],
      \ [ 1, -1], [ 1, 0], [ 1, 1],
      \ ]

let s:board_top = '┌───┬───┬───┬───┬───┬───┬───┬───┐'
let s:board_separator = '├───┼───┼───┼───┼───┼───┼───┼───┤'
let s:board_bottom = '└───┴───┴───┴───┴───┴───┴───┴───┘'
let s:empty_display = '   '
let s:stone_display = '▐█▌'
let s:cpu_delay_ms = 80

function! s:get_player_color(player) abort
  " First player gets black, second player gets white
  if a:player == s:state.first_player
    return 'black'
  else
    return 'white'
  endif
endfunction

function! s:get_player_display(player) abort
  let color = s:get_player_color(a:player)
  if a:player == 'user'
    return printf('You (%s)', color)
  else
    return printf('CPU (%s)', color)
  endif
endfunction

function! s:ensure_highlights() abort
  if s:state.highlights_defined
    return
  endif
  
  highlight ReversiBoardGrid ctermfg=0 ctermbg=22 guifg=#000000 guibg=#006400
  highlight ReversiStoneWhite ctermfg=15 ctermbg=22 cterm=bold guifg=#FFFFFF guibg=#006400 gui=bold
  highlight ReversiStoneBlack ctermfg=0 ctermbg=22 cterm=bold guifg=#000000 guibg=#006400 gui=bold
  
  let s:state.highlights_defined = 1
endfunction

function! s:ensure_prop_types() abort
  if s:state.prop_types_defined
    return
  endif
  
  if has('nvim')
    " Neovim uses namespaces instead of text properties
    if s:state.ns_id == -1
      let s:state.ns_id = nvim_create_namespace('reversi')
    endif
  elseif has('textprop')
    " Vim text properties
    silent! call prop_type_add('reversi_grid', {'highlight': 'ReversiBoardGrid', 'priority': 10})
    silent! call prop_type_add('reversi_white', {'highlight': 'ReversiStoneWhite', 'priority': 20})
    silent! call prop_type_add('reversi_black', {'highlight': 'ReversiStoneBlack', 'priority': 20})
  endif
  
  let s:state.prop_types_defined = 1
endfunction

function! s:opponent(disc) abort
  if a:disc == s:Disc.user
    return s:Disc.cpu
  elseif a:disc == s:Disc.cpu
    return s:Disc.user
  endif
  return s:Disc.empty
endfunction

function! s:in_bounds(r, c) abort
  return a:r >= 0 && a:r < 8 && a:c >= 0 && a:c < 8
endfunction

function! s:cursor_to_board() abort
  if s:state.buf < 0 || bufnr('%') != s:state.buf
    return [v:null, v:null]
  endif

  let lnum = line('.')
  let col_bytes = col('.') - 1

  if lnum < 2 || lnum > 16 || lnum % 2 == 1
    return [v:null, v:null]
  endif

  let board_row = lnum / 2 - 1

  let line_text = getline(lnum)
  if empty(line_text)
    return [v:null, v:null]
  endif

  let char_col = strchars(strpart(line_text, 0, col_bytes)) + 1
  if char_col < 2
    return [v:null, v:null]
  endif

  let offset = char_col - 2
  let cell_width = 4
  if offset < 0
    return [v:null, v:null]
  endif

  let pos_in_segment = offset % cell_width
  if pos_in_segment >= 3
    return [v:null, v:null]
  endif

  let board_col = offset / cell_width
  if board_col < 0 || board_col > 7
    return [v:null, v:null]
  endif

  return [board_row, board_col]
endfunction

function! s:cell_to_screen_position(row, col) abort
  if a:row < 0 || a:row > 7 || a:col < 0 || a:col > 7
    return [v:null, v:null]
  endif

  let lnum = a:row * 2 + 2
  let line_str = getbufline(s:state.buf, lnum)[0]
  if empty(line_str)
    return [v:null, v:null]
  endif

  let char_index = a:col * 4 + 2
  let prefix = strcharpart(line_str, 0, char_index)
  let byte_index = strlen(prefix) + 1

  return [lnum, byte_index]
endfunction

function! s:restore_cursor() abort
  if !has_key(s:state.last_cursor, 'row') || s:state.win < 0 || !win_id2win(s:state.win)
    return
  endif
  if winbufnr(s:state.win) != s:state.buf
    return
  endif

  let [lnum, col_byte] = s:cell_to_screen_position(s:state.last_cursor.row, s:state.last_cursor.col)
  if lnum isnot v:null && col_byte isnot v:null
    call win_execute(s:state.win, 'call cursor(' . lnum . ', ' . col_byte . ')')
  endif
endfunction

function! s:init_board() abort
  let board = []
  for r in range(8)
    let row = []
    for c in range(8)
      call add(row, s:Disc.empty)
    endfor
    call add(board, row)
  endfor
  
  " Standard Reversi starting position
  " First player (black) gets top-left and bottom-right
  " Second player (white) gets top-right and bottom-left
  let first_disc = s:state.first_player == 'user' ? s:Disc.user : s:Disc.cpu
  let second_disc = s:state.first_player == 'user' ? s:Disc.cpu : s:Disc.user
  
  let board[3][3] = first_disc
  let board[4][4] = first_disc
  let board[3][4] = second_disc
  let board[4][3] = second_disc
  
  return board
endfunction

function! s:count_scores() abort
  let user_count = 0
  let cpu_count = 0
  for r in range(8)
    for c in range(8)
      let cell = s:state.board[r][c]
      if cell == s:Disc.user
        let user_count += 1
      elseif cell == s:Disc.cpu
        let cpu_count += 1
      endif
    endfor
  endfor
  return [user_count, cpu_count]
endfunction

function! s:board_has_empty() abort
  for r in range(8)
    for c in range(8)
      if s:state.board[r][c] == s:Disc.empty
        return 1
      endif
    endfor
  endfor
  return 0
endfunction

function! s:get_flips(board, row, col, player_disc) abort
  if a:board[a:row][a:col] != s:Disc.empty
    return []
  endif
  let opp = s:opponent(a:player_disc)
  let flips = []

  for dir in s:directions
    let r = a:row + dir[0]
    let c = a:col + dir[1]
    let captured = []

    while s:in_bounds(r, c) && a:board[r][c] == opp
      call add(captured, {'r': r, 'c': c})
      let r += dir[0]
      let c += dir[1]
    endwhile

    if s:in_bounds(r, c) && a:board[r][c] == a:player_disc && len(captured) > 0
      call extend(flips, captured)
    endif
  endfor

  return flips
endfunction

function! s:get_valid_moves(board, player_disc) abort
  let moves = []
  for r in range(8)
    for c in range(8)
      let flips = s:get_flips(a:board, r, c, a:player_disc)
      if len(flips) > 0
        call add(moves, {'row': r, 'col': c, 'flips': flips})
      endif
    endfor
  endfor
  return moves
endfunction

function! s:apply_move(board, row, col, player_disc, flips) abort
  let a:board[a:row][a:col] = a:player_disc
  for pos in a:flips
    let a:board[pos.r][pos.c] = a:player_disc
  endfor
endfunction

function! s:set_status(message) abort
  let s:state.status_message = a:message
endfunction

function! s:render() abort
  if s:state.buf < 0 || !bufexists(s:state.buf)
    return
  endif

  call s:ensure_highlights()
  call s:ensure_prop_types()

  let lines = [s:board_top]
  for r in range(8)
    let row_chunks = ['│']
    for c in range(8)
      let cell = s:state.board[r][c]
      if cell == s:Disc.empty
        call add(row_chunks, s:empty_display)
      else
        call add(row_chunks, s:stone_display)
      endif
      call add(row_chunks, '│')
    endfor
    call add(lines, join(row_chunks, ''))
    if r < 7
      call add(lines, s:board_separator)
    else
      call add(lines, s:board_bottom)
    endif
  endfor

  let board_line_count = len(lines)

  let [user_count, cpu_count] = s:count_scores()
  let engine_type = reversi#eval#get_engine_type()
  let user_display = s:get_player_display('user')
  let cpu_display = s:get_player_display('cpu')
  call add(lines, '')
  call add(lines, printf('%s: %d    %s: %d    Engine: %s', user_display, user_count, cpu_display, cpu_count, engine_type))

  if s:state.game_over
    call add(lines, 'Turn: (game finished)')
  else
    let current_player = s:get_player_display(s:state.turn)
    call add(lines, printf('Turn: %s', current_player))
  endif

  if s:state.status_message != ''
    call add(lines, s:state.status_message)
  endif

  call setbufvar(s:state.buf, '&modifiable', 1)
  call setbufvar(s:state.buf, '&readonly', 0)
  call deletebufline(s:state.buf, 1, '$')
  call setbufline(s:state.buf, 1, lines)
  call setbufvar(s:state.buf, '&modifiable', 0)
  call setbufvar(s:state.buf, '&readonly', 1)

  " Apply highlighting
  if has('nvim')
    " Neovim highlighting using namespaces
    call nvim_buf_clear_namespace(s:state.buf, s:state.ns_id, 0, -1)
    
    " Highlight board grid
    for i in range(board_line_count)
      call nvim_buf_add_highlight(s:state.buf, s:state.ns_id, 'ReversiBoardGrid', i, 0, -1)
    endfor
    
    " Highlight stones
    for r in range(8)
      for c in range(8)
        let cell = s:state.board[r][c]
        if cell != s:Disc.empty
          " Determine color based on first player
          let player = cell == s:Disc.user ? 'user' : 'cpu'
          let color = s:get_player_color(player)
          let hl_group = color == 'black' ? 'ReversiStoneBlack' : 'ReversiStoneWhite'
          let line_idx = r * 2 + 1
          let line_str = lines[line_idx]
          let start_char = 1 + c * 4
          let end_char = start_char + 3
          let start_col = strlen(strcharpart(line_str, 0, start_char))
          let end_col = strlen(strcharpart(line_str, 0, end_char))
          call nvim_buf_add_highlight(s:state.buf, s:state.ns_id, hl_group, line_idx, start_col, end_col)
        endif
      endfor
    endfor
  elseif has('textprop')
    " Vim text properties
    call prop_remove({'type': 'reversi_grid', 'all': 1, 'bufnr': s:state.buf})
    call prop_remove({'type': 'reversi_white', 'all': 1, 'bufnr': s:state.buf})
    call prop_remove({'type': 'reversi_black', 'all': 1, 'bufnr': s:state.buf})

    for i in range(board_line_count)
      call prop_add(i + 1, 1, {'type': 'reversi_grid', 'end_lnum': i + 1, 'end_col': strlen(lines[i]) + 1, 'bufnr': s:state.buf})
    endfor

    for r in range(8)
      for c in range(8)
        let cell = s:state.board[r][c]
        if cell != s:Disc.empty
          " Determine color based on first player
          let player = cell == s:Disc.user ? 'user' : 'cpu'
          let color = s:get_player_color(player)
          let prop_type = color == 'black' ? 'reversi_black' : 'reversi_white'
          let line_idx = r * 2 + 1
          let line_str = lines[line_idx]
          let start_char = 1 + c * 4
          let end_char = start_char + 3
          let start_col = strlen(strcharpart(line_str, 0, start_char)) + 1
          let end_col = strlen(strcharpart(line_str, 0, end_char)) + 1
          call prop_add(line_idx + 1, start_col, {'type': prop_type, 'end_col': end_col, 'bufnr': s:state.buf})
        endif
      endfor
    endfor
  endif

  call s:restore_cursor()
endfunction

function! s:finish_game(reason) abort
  let s:state.game_over = 1
  let s:state.turn = ''
  let [user_count, cpu_count] = s:count_scores()
  
  if user_count > cpu_count
    let outcome = 'You win!'
  elseif cpu_count > user_count
    let outcome = 'CPU wins.'
  else
    let outcome = 'Draw.'
  endif
  
  let user_display = s:get_player_display('user')
  let cpu_display = s:get_player_display('cpu')
  let summary = printf('%s Final score -> %s: %d, %s: %d', outcome, user_display, user_count, cpu_display, cpu_count)
  call s:set_status(printf('%s %s', a:reason, summary))
  call s:render()
  echohl WarningMsg | echomsg printf('Game over. %s %s', a:reason, summary) | echohl None
endfunction

function! s:check_game_over() abort
  if s:state.game_over
    return 1
  endif

  let user_moves = s:get_valid_moves(s:state.board, s:Disc.user)
  let cpu_moves = s:get_valid_moves(s:state.board, s:Disc.cpu)
  let no_moves_for_anyone = len(user_moves) == 0 && len(cpu_moves) == 0
  let board_full = !s:board_has_empty()

  if board_full || no_moves_for_anyone
    let reason = board_full ? 'Board is full.' : 'No valid moves remain.'
    call s:finish_game(reason)
    return 1
  endif

  return 0
endfunction

function! reversi#cpu_move_or_pass() abort
  if s:state.game_over || s:state.turn != 'cpu'
    return
  endif
  if s:state.buf < 0 || !bufexists(s:state.buf)
    return
  endif

  let cpu_moves = s:get_valid_moves(s:state.board, s:Disc.cpu)
  if len(cpu_moves) == 0
    if s:check_game_over()
      return
    endif
    let s:state.turn = 'user'
    call s:set_status('CPU has no valid moves. Your turn.')
    call s:render()
    return
  endif

  let [move, score] = reversi#eval#best_move(s:state.board, cpu_moves, s:state.discs)
  call s:apply_move(s:state.board, move.row, move.col, s:Disc.cpu, move.flips)
  call s:set_status(printf('CPU placed at (%d, %d).', move.row + 1, move.col + 1))
  let s:state.turn = 'user'
  call s:render()

  if s:check_game_over()
    return
  endif

  let user_moves = s:get_valid_moves(s:state.board, s:Disc.user)
  if len(user_moves) == 0
    let s:state.turn = 'cpu'
    call s:set_status('You have no valid moves. CPU moves again.')
    call s:render()
    if s:check_game_over()
      return
    endif
    call timer_start(s:cpu_delay_ms, {-> reversi#cpu_move_or_pass()})
  endif
endfunction

function! reversi#handle_user_move() abort
  if s:state.game_over || s:state.buf < 0 || bufnr('%') != s:state.buf
    return
  endif

  if s:state.turn != 'user'
    call s:set_status('Please wait for the CPU to move.')
    call s:render()
    return
  endif

  let user_moves = s:get_valid_moves(s:state.board, s:Disc.user)
  if len(user_moves) == 0
    let s:state.turn = 'cpu'
    call s:set_status('You have no valid moves. Passing to CPU.')
    call s:render()
    if s:check_game_over()
      return
    endif
    call timer_start(s:cpu_delay_ms, {-> reversi#cpu_move_or_pass()})
    return
  endif

  let [row, col] = s:cursor_to_board()
  if row is v:null || col is v:null
    call s:set_status('Move the cursor onto a playable square within the board.')
    call s:render()
    return
  endif

  let s:state.last_cursor = {'row': row, 'col': col}

  let flips = s:get_flips(s:state.board, row, col, s:Disc.user)
  if len(flips) == 0
    call s:set_status('Invalid move: no discs flipped.')
    call s:render()
    return
  endif

  call s:apply_move(s:state.board, row, col, s:Disc.user, flips)
  call s:set_status(printf('You placed at (%d, %d).', row + 1, col + 1))
  let s:state.turn = 'cpu'
  call s:render()

  if s:check_game_over()
    return
  endif

  call timer_start(s:cpu_delay_ms, {-> reversi#cpu_move_or_pass()})
endfunction

function! s:reset_state() abort
  " Randomly choose who goes first
  let first_turn = str2nr(reltimestr(reltime())) % 2 == 0 ? 'user' : 'cpu'
  let s:state.first_player = first_turn
  let s:state.board = s:init_board()
  let s:state.last_cursor = {'row': 3, 'col': 3}
  let s:state.turn = first_turn
  let s:state.game_over = 0
  
  let first_display = s:get_player_display(first_turn)
  if first_turn == 'user'
    let s:state.status_message = printf('%s go first (black stones). Move the cursor and press <CR>.', first_display)
  else
    let s:state.status_message = printf('%s goes first (black stones).', first_display)
  endif
endfunction

function! reversi#start() abort
  if s:state.buf >= 0 && bufexists(s:state.buf)
    echohl WarningMsg | echomsg 'An Reversi session is already active.' | echohl None
    execute 'buffer' s:state.buf
    return
  endif

  call s:reset_state()
  call s:ensure_highlights()
  call s:ensure_prop_types()

  let buf = bufadd('Reversi')
  call bufload(buf)
  let s:state.buf = buf

  call setbufvar(buf, '&buftype', 'nofile')
  call setbufvar(buf, '&swapfile', 0)
  call setbufvar(buf, '&bufhidden', 'wipe')
  call setbufvar(buf, '&modifiable', 0)
  call setbufvar(buf, '&readonly', 1)
  call setbufvar(buf, '&filetype', 'reversi')

  execute 'buffer' buf
  let s:state.win = win_getid()

  execute 'nnoremap <buffer> <silent> <CR> :call reversi#handle_user_move()<CR>'

  execute 'autocmd BufWipeout <buffer=' . buf . '> call s:on_buf_wipeout()'

  call s:render()

  if s:state.turn == 'cpu' && !s:state.game_over
    call timer_start(s:cpu_delay_ms, {-> reversi#cpu_move_or_pass()})
  endif
endfunction

function! s:on_buf_wipeout() abort
  let s:state.buf = -1
  let s:state.game_over = 0
  let s:state.win = -1
endfunction
