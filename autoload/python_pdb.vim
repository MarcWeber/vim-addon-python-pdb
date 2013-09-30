" exec vam#DefineAndBind('s:c','g:python_pdb','{}')
if !exists('g:python_pdb') | let g:python_pdb = {} | endif | let s:c = g:python_pdb
let s:c.ctxs = get(s:c, 'ctxs', {})
let s:c.next_ctx_nr = get(s:c, 'ctx_nr', 1)

" You can also run /bin/sh and use require 'debug' in your ruby scripts

fun! python_pdb#Setup(...)
  if a:0 > 0
    " TODO quoting?
    let cmd = join(a:000," ")
  else
    let cmd = "python"
    let cmd = input('ruby command:', cmd." ".expand('%'))
  endif
  let ctx = python_pdb#RubyBuffer({'buf_name' : 'RUBY_DEBUG_PROCESS', 'cmd': 'socat "EXEC:"'.shellescape(cmd).'",pty,stderr" -', 'move_last' : 1})
  let ctx.ctx_nr = s:c.next_ctx_nr
  let ctx.vim_managed_breakpoints = []
  let ctx.next_breakpoint_nr = 1
  let s:c.ctxs[s:c.next_ctx_nr] = ctx
  let s:c.active_ctx = s:c.next_ctx_nr
  let s:c.next_ctx_nr = 1
  call PythonPdbMappings()
  call python_pdb#UpdateBreakPoints()
endf

fun! python_pdb#RubyBuffer(...)
  let ctx = a:0 > 0 ? a:1 : {}

  fun ctx.terminated()
    call append('$','END')
    if has_key(self, 'curr_pos')
      unlet self.curr_pos
    endif
    call python_pdb#SetCurr()
  endf

  call async_porcelaine#LogToBuffer(ctx)
  let ctx.receive = function('python_pdb#Receive')
  return ctx
endf

fun! python_pdb#Receive(...) dict
  call call(function('python_pdb#Receive2'), a:000, self)
endf
fun! python_pdb#Receive2(...) dict
  let self.received_data = get(self,'received_data','').a:1
  let lines = split(self.received_data,"\n",1)

  let feed = []
  let s = ""
  let reg_rdb = '^> \([^(]\+\)(\(\d\+\)).*'
  let set_pos = "let self.curr_pos = {'filename':m[1], 'line': m[2]} | call python_pdb#SetCurr(m[1], m[2])"

  " process complete lines
  for l in lines[0:-2]
    let m = matchlist(l, reg_rdb)
    if len(m) > 0 && m[1] != ''
      let m_cache = m
      if filereadable(m_cache[1])
        exec set_pos
      endif
    endif
    let s .= l."\n"
  endfor

  " keep rest of line
  let self.received_data = lines[-1]

  if len(s) > 0
    call async#DelayUntilNotDisturbing('process-pid'. self.pid, {'delay-when': ['buf-invisible:'. self.bufnr], 'fun' : self.delayed_work, 'args': [s, 1], 'self': self} )
  endif
endf

" SetCurr() (no debugging active
" SetCurr(file, line)
" mark that line as line which will be executed next
fun! python_pdb#SetCurr(...)
  " list of all current execution points of all known ruby processes
  let curr_poss = []

  for [k,v] in items(s:c.ctxs)
    " process has finished? no more current lines
    if has_key(v, 'curr_pos')
      let cp = v.curr_pos
      let buf_nr = bufnr(cp.filename)
      if (buf_nr == -1)
        exec 'sp '.fnameescape(cp.filename)
        let buf_nr = bufnr(cp.filename)
      endif
      call add(curr_poss, [buf_nr, cp.line, "python_pdb_current_line"])
    endif
    unlet k v
  endfor

  " jump to new execution point
  if a:0 != 0
    call buf_utils#GotoBuf(a:1, {'create_cmd': 'sp'})
    exec a:2
    " exec a:2
    " call python_pdb#UpdateVarView()
  endif
  call vim_addon_signs#Push("python_pdb_current_line", curr_poss )
endf

fun! python_pdb#Debugger(cmd, ...)
  let ctx_nr = a:0 > 0 ? a:1 : s:c.active_ctx
  let ctx = s:c.ctxs[ctx_nr]
  if a:cmd =~ '\%(step\|next\|finish\|cont\)'
    call ctx.write(a:cmd."\n")
    if a:cmd == 'cont'
      unlet ctx.curr_pos
      call python_pdb#SetCurr()
    endif
  elseif a:cmd == 'toggle_break_point'
    call python_pdb#ToggleLineBreakpoint()
  else
    throw "unexpected command
  endif
endf

let s:auto_break_end = '== break points end =='
fun! python_pdb#BreakPointsBuffer()
  let buf_name = "XDEBUG_BREAK_POINTS_VIEW"
  let cmd = buf_utils#GotoBuf(buf_name, {'create_cmd':'sp'} )
  if cmd == 'e'
    " new buffer, set commands etc
    let s:c.var_break_buf_nr = bufnr('%')
    noremap <buffer> <cr> :call python_pdb#UpdateBreakPoints()<cr>
    call append(0,['# put the breakpoints here, prefix with # to deactivate:', s:auto_break_end
          \ , 'python_pdb supports:'
          \ , 'file:line[, condition]'
          \ , ''
          \ , 'python also supports temporary breakpoints (tbreak).'
          \ , 'Use the debugger window to add them (-> vim-addon-async documentation)'
          \ , ''
          \ , 'for now all breakpoints (also the ones you added manually) get cleared and recreated.'
          \ , ''
          \ , 'hit <cr> to send updated breakpoints to processes'
          \ ])
    setlocal noswapfile
    " it may make sense storing breakpoints. So allow writing the breakpoints
    " buffer
    " set buftype=nofile
  endif

  let buf_nr = bufnr(buf_name)
  if buf_nr == -1
    exec 'sp '.fnameescape(buf_name)
  endif
endf


fun! python_pdb#UpdateBreakPoints()
  let signs = []
  let points = []
  let dict_new = {}
  call python_pdb#BreakPointsBuffer()

  let r_line        = '^\([^:]\+\):\(\d\+\)\%(\s*,\s*\(\S.*\)\)\?$'

  for l in getline('0',line('$'))
    if l =~ s:auto_break_end | break | endif
    if l =~ '^#' | continue | endif
    silent! unlet args
    let condition = ""

    let m = matchlist(l, r_line)
    if !empty(m)
      let point = {}
      if (filereadable(m[1]))
        let point['file'] = m[1]
      else
        throw "file ".point['file'].' not readable!'
      endif
      let point['line'] = m[2]
      let point['condition'] = m[3]

      call add(points, point)
    endif
  endfor

  " calculate markers:
  " we only show markers for file.line like breakpoints
  for p in points
    if has_key(p, 'file') && has_key(p, 'line')
      call add(signs, [bufnr(p.file), p.line, 'python_pdb_breakpoint'])
    endif
  endfor

  call vim_addon_signs#Push("python_pdb_breakpoint", signs )

  for ctx in values(s:c.ctxs)
    if !has_key(ctx,'status')

      " drop all breakpoints:
      call ctx.write("clear\ny\n")

      " add all breakpoints
      for b in points
        call ctx.write('break '. p.file .':'. p.line . (p.condition == '' ? '' : ', '. p['condition']). "\n")
      endfor
    endif
  endfor
endf


fun! python_pdb#ToggleLineBreakpoint()
  " yes, this implementation somehow sucks ..
  let file = expand('%')
  let line = getpos('.')[1]

  let old_win_nr = winnr()
  let old_buf_nr = bufnr('%')

  if !has_key(s:c,'var_break_buf_nr')
    call xdebug#BreakPointsBuffer()
    let restore = "bufnr"
  else
    let win_nr = bufwinnr(get(s:c, 'var_break_buf_nr', -1))

    if win_nr == -1
      let restore = 'bufnr'
      exec 'b '.s:c.var_break_buf_nr
    else
      let restore = 'active_window'
      exec win_nr.' wincmd w'
    endif

  endif

  " BreakPoint buffer should be active now.
  let pattern = escape(file,'\').':'.line
  let line = file.':'.line
  normal gg
  let found = search(pattern,'', s:auto_break_end)
  if found > 0
    " remove breakpoint
    exec found.'g/./d'
  else
    " add breakpoint
    call append(0, line)
  endif
  call python_pdb#UpdateBreakPoints()
  if restore == 'bufnr'
    exec 'b '.old_buf_nr
  else
    exec old_win_nr.' wincmd w'
  endif
endf
