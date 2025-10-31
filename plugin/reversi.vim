" Reversi plugin for Vim
if exists('g:loaded_reversi')
  finish
endif
let g:loaded_reversi = 1

command! Reversi call reversi#start()
