" simple python_pdb implementation following the execution steps ..{{{1

if !exists('g:python_pdb') | let g:python_pdb = {} | endif | let s:c = g:python_pdb

command! -nargs=* AsyncPythonPdb call python_pdb#Setup(<f-args>)

sign define python_pdb_current_line text=>> linehl=Type
" not used yet:
sign define python_pdb_breakpoint text=O   linehl=

if !exists('*PythonPdbMappings')
  fun! PythonPdbMappings()
     noremap <F5> :call python_pdb#Debugger("step")<cr>
     noremap <F6> :call python_pdb#Debugger("next")<cr>
     noremap <F7> :call python_pdb#Debugger("finish")<cr>
     noremap <F8> :call python_pdb#Debugger("cont")<cr>
     noremap <F9> :call python_pdb#Debugger("toggle_break_point")<cr>
     " noremap \xv :XDbgVarView<cr>
     " vnoremap \xv y:XDbgVarView<cr>GpV<cr>
  endf
endif
