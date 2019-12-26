"=============================================================================
"     File: autoload/jupyter.vim
"  Created: 02/21/2018, 22:24
"   Author: Bernie Roesler
"
"  Description: Autoload vim functions for use in jupyter-vim plugin
"
"=============================================================================
"        Python Initialization:
"-----------------------------------------------------------------------------
" Neovim doesn't have the pythonx command, so we define a new command Pythonx
" that works for both vim and neovim.
if has('pythonx')
    command! -range -nargs=+ Pythonx <line1>,<line2>pythonx <args>
elseif has('python3')
    command! -range -nargs=+ Pythonx <line1>,<line2>python3 <args>
elseif has('python')
    command! -range -nargs=+ Pythonx <line1>,<line2>python <args>
endif

" Define Pyeval: python str -> vim variable
function! Pyevalx(str) abort
    if has('pythonx')
        return pyxeval(a:str)
    elseif has('python3')
        return py3eval(a:str)
    elseif has('python')
        return pyeval(a:str)
    endif
endfunction

" See ~/.vim/bundle/jedi-vim/autoload/jedi.vim for initialization routine
function! s:init_python() abort
    let s:init_outcome = 0
    let init_lines = [
          \ 'import sys; import os; import vim',
          \ 'vim_path, _ = os.path.split(vim.eval("expand(''<sfile>:p:h'')"))',
          \ 'vim_pythonx_path = os.path.join(vim_path, "pythonx")',
          \ 'if vim_pythonx_path not in sys.path:',
          \ '    sys.path.append(vim_pythonx_path)',
          \ 'try:',
          \ '    import jupyter_vim',
          \ '    from message_parser import str_to_py, find_jupyter_kernels',
          \ 'except Exception as exc:',
          \ '    vim.command(''let s:init_outcome = "could not import jupyter_vim:'
          \                    .'{0}: {1}"''.format(exc.__class__.__name__, exc))',
          \ 'else:',
          \ '    vim.command(''let s:init_outcome = 1'')']

    " Try running lines via python, which will set script variable
    try
        execute 'Pythonx exec('''.escape(join(init_lines, '\n'), "'").''')'
    catch
        throw printf('[jupyter-vim] s:init_python: failed to run Python for initialization: %s.', v:exception)
    endtry

    if s:init_outcome is 0
        throw '[jupyter-vim] s:init_python: failed to run Python for initialization.'
    elseif s:init_outcome isnot 1
        throw printf('[jupyter-vim] s:init_python: %s.', s:init_outcome)
    endif

    return 1
endfunction

" Public initialization routine
let s:_init_python = -1
function! jupyter#init_python() abort
    if s:_init_python == -1
        let s:_init_python = 0
        try
            let s:_init_python = s:init_python()
            let s:_init_python = 1
        catch /^jupyter/
            " Only catch errors from jupyter-vim itself here, so that for
            " unexpected Python exceptions the traceback will be shown
            echoerr 'Error: jupyter-vim failed to initialize Python: '
                        \ . v:exception . ' (in ' . v:throwpoint . ')'
            " throw v:exception
        endtry
    endif
    return s:_init_python
endfunction

"-----------------------------------------------------------------------------
"        Vim -> Jupyter Public Functions:
"-----------------------------------------------------------------------------
function! jupyter#Connect(...) abort
    " call jupyter#init_python()
    let l:kernel_file = a:0 > 0 ? a:1 : '*.json'
    Pythonx jupyter_vim.connect_to_kernel(
                \ str_to_py(vim.current.buffer.vars['jupyter_kernel_type']),
                \ filename=vim.eval('l:kernel_file'))
endfunction

function! jupyter#CompleteConnect(ArgLead, CmdLine, CursorPos) abort
    " Get kernel id from python
    let l:kernel_ids = Pyeval(find_jupyter_kernels())
    " Filter id matching user arg
    call filter(l:kernel_ids, '-1 != match(v:val, a:ArgLead)')
    " Return list
    return l:kernel_ids
endfunction

function! jupyter#Disconnect(...) abort
    Pythonx jupyter_vim.disconnect_from_kernel()
endfunction

function! jupyter#JupyterCd(...) abort 
    " Behaves just like typical `cd`.
    let l:dirname = a:0 ? a:1 : "$HOME"
    " Helpers:
    " " . -> vim cwd
    if l:dirname ==# '.' | let l:dirname = getcwd() | endif
    " " % -> %:p
    if l:dirname ==# expand('%') | let l:dirname = '%:p:h' | endif
    " Expand (to get %)
    let l:dirname = expand(l:dirname)
    let l:dirname = escape(l:dirname, '"')
    Pythonx jupyter_vim.change_directory(vim.eval('l:dirname'))
endfunction

function! jupyter#RunFile(...) abort
    " filename is the last argument on the command line
    let l:flags = (a:0 > 1) ? join(a:000[:-2], ' ') : ''
    let l:filename = a:0 ? a:000[-1] : expand('%:p')
    if b:jupyter_kernel_type ==# 'python'
        Pythonx jupyter_vim.run_file_in_ipython(
                    \ flags=vim.eval('l:flags'),
                    \ filename=vim.eval('l:filename'))
    elseif b:jupyter_kernel_type ==# 'julia'
        if l:flags !=# ''
            echoerr 'RunFile in kernel type "julia" doesn''t support flags.'
                \ . ' All arguments except the last (file location) will be'
                \ . ' ignored.'
        endif
        JupyterSendCode 'include("""'.escape(l:filename, '"').'""")'
    else
        echoerr 'I don''t know how to do the `RunFile` command in Jupyter'
            \ . ' kernel type "' . b:jupyter_kernel_type . '"'
    endif
endfunction

function! jupyter#SendCell() abort
    Pythonx jupyter_vim.run_cell()
endfunction

function! jupyter#SendCode(code) abort
    " NOTE: 'run_command' gives more checks than just raw 'send'
    Pythonx jupyter_vim.run_command(vim.eval('a:code'))
endfunction

function! jupyter#SendRange() range abort
    execute a:firstline . ',' . a:lastline . 'Pythonx jupyter_vim.send_range()'
endfunction

function! jupyter#SendCount(count) abort
    " TODO move this function to pure(ish) python like SendRange
    let sel_save = &selection
    let cb_save = &clipboard
    let reg_save = @@
    try
        set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
        silent execute 'normal! ' . a:count . 'yy'
        let l:cmd = @@
    finally
        let @@ = reg_save
        let &selection = sel_save
        let &clipboard = cb_save
    endtry
    call jupyter#SendCode(l:cmd)
endfunction

function! jupyter#TerminateKernel(kill, ...) abort
    if a:kill
        let l:sig='SIGKILL'
    elseif a:0 > 0
        let l:sig=a:1
        echom 'Sending signal: '.l:sig
    else
        let l:sig='SIGTERM'
    endif
    " Check signal here?
    execute 'Pythonx jupyter_vim.signal_kernel(jupyter_vim.signal.'.l:sig.')'
endfunction

function! jupyter#UpdateShell() abort
    Pythonx jupyter_vim.update_console_msgs()
endfunction

"-----------------------------------------------------------------------------
"        Operator Function:
"-----------------------------------------------------------------------------

" Factory: callback(text) -> operator_function
function! s:get_opfunc(callback) abort
    " Define the function
    function! s:res_opfunc(type) abort closure
        " From tpope/vim-scriptease
        let saved = [&selection, &clipboard, @@]
        try
            set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
            " Invoked from visual mode (V, v, ^V)
            if a:type =~# '^.$'
                silent exe 'norm! `<' . a:type . '`>y'
            " Invoked from operator pending (line, block or visual)
            else
                silent exe 'norm! `[' . get({'l': 'V', 'b': '\<C-V>'}, a:type[0], 'v') . '`]y'
            endif
            redraw
            let l:text = @@
        finally
            let [&selection, &clipboard, @@] = saved
        endtry

        " Call callback
        call a:callback(l:text)
    endfunction

    " Return the closure
    return funcref('s:res_opfunc')
endfunction

" Operator function to run selected|operator text
function! s:opfunc_run_code(type)
    call s:get_opfunc(function('jupyter#SendCode'))(a:type)
endfunction

"-----------------------------------------------------------------------------
"        Auxiliary Functions:
"-----------------------------------------------------------------------------
" vint: next-line -ProhibitNoAbortFunction
function! jupyter#PythonDbstop() abort
    " Set a debugging breakpoint for use with pdb
    normal! Oimport pdb; pdb.set_trace()
    normal! j
endfunction

" vint: next-line -ProhibitNoAbortFunction
function! jupyter#MakeStandardCommands()
    " Standard commands, called from each ftplugin so that we only map the
    " keys buffer-local for select filetypes.
    command! -buffer -nargs=* -complete=customlist,jupyter#CompleteConnect
          \ JupyterConnect call jupyter#Connect(<f-args>)
    command! -buffer -nargs=0    JupyterDisconnect      call jupyter#Disconnect()
    command! -buffer -nargs=1    JupyterSendCode        call jupyter#SendCode(<args>)
    command! -buffer -count      JupyterSendCount       call jupyter#SendCount(<count>)
    command! -buffer -range -bar JupyterSendRange       <line1>,<line2>call jupyter#SendRange()
    command! -buffer -nargs=0    JupyterSendCell        call jupyter#SendCell()
    command! -buffer -nargs=0    JupyterUpdateShell     call jupyter#UpdateShell()
    command! -buffer -nargs=? -complete=dir  JupyterCd  call jupyter#JupyterCd(<f-args>)
    command! -buffer -nargs=? -bang  JupyterTerminateKernel  call jupyter#TerminateKernel(<bang>0, <f-args>)
    command! -buffer -nargs=* -complete=file
                \ JupyterRunFile update | call jupyter#RunFile(<f-args>)
endfunction

function! jupyter#MapStandardKeys() abort
    " Standard keymaps, called from each ftplugin so that we only map the keys
    " buffer-local for select filetypes.
    nnoremap <buffer> <silent> <localleader>R       :JupyterRunFile<CR>

    " Change to directory of current file
    nnoremap <buffer> <silent> <localleader>d       :JupyterCd %:p:h<CR>

    " Send just the current line
    nnoremap <buffer> <silent> <localleader>X       :JupyterSendCell<CR>
    nnoremap <buffer> <silent> <localleader>E       :JupyterSendRange<CR>

    " Send the text to jupyter kernel
    nnoremap <buffer> <silent> <localleader>e       :<C-u>set operatorfunc=<SID>opfunc_run_code<CR>g@
    vnoremap <buffer> <silent> <localleader>e       :<C-u>call <SID>opfunc_run_code(visualmode())<CR>gv

    nnoremap <buffer> <silent> <localleader>U       :JupyterUpdateShell<CR>

endfunction

"-----------------------------------------------------------------------------
"        Helpers
"-----------------------------------------------------------------------------

" Timer callback to fill jupyter console buffer
function! jupyter#UpdateEchom(timer) abort
    Pythonx jupyter_vim.timer_echom()
endfunction

"=============================================================================
"=============================================================================
