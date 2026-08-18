/* --- A live-session server for editors -----------------------------------
 > File:            pop/lib/lib/swank.p
 > Purpose:         Evaluate, stream output and report mishaps over a socket
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   HELP * SWANK
 > Related Files:   tools/pop11-swank, editors/emacs/, LIB * JSONRPC,
 >                  LIB * INCOMPLETE_CODE, tools/tests/test_swank.p
 >
 > Named after SLIME's swank, and for the same reason: the interesting
 > thing an editor can talk to is not a compiler but a RUNNING SESSION.
 > The LSP server (pop/lsp/pop11_lsp.p) answers questions about text.
 > This answers questions about a live heap -- what a name is bound to
 > now, what a procedure printed while it ran, which frames were on the
 > stack when it died.
 >
 > Over stdio none of that is possible: there is one channel and the
 > compiler's reader owns it.  Over a socket the server can stream
 > output as it is produced and report a mishap as data rather than as
 > a block of text the client has to scrape.
 >
 > Requests, all JSON-RPC 2.0 with Content-Length framing:
 >
 >   swank/connect     who this is, and the pid to signal
 >   swank/eval        compile code here; streams swank/output; returns
 >                     values, or a structured mishap, or interrupted
 >   swank/describe    what a name is bound to in this session
 >   swank/state       evals so far, heap, pid
 >   swank/stop        close the connection and stop serving
 >
 > INTERRUPTING.  A request cannot arrive while an evaluation is running
 > -- Pop-11 is single-threaded, and the server is inside the user's
 > loop.  The client sends SIGINT to the pid from swank/connect, which
 > the engine delivers at the next check planted in the running code,
 > and the trap here turns it into an ordinary "interrupted" result with
 > the session intact.  (That check is I_CHECK; it was an empty stub on
 > arm64 and riscv64 until 2026-08-15, which is why runaway loops used
 > to be unkillable on those ports.)
 >
 > SCOPE.  One connection served at a time, one evaluation at a time.
 > swank_serve blocks, so calling it from a live session hands that
 > session to the editor -- which is the point: everything you have
 > already defined and loaded is what the editor then talks to.
 */
compile_mode :pop11 +strict;

uses jsonrpc;
uses incomplete_code;

section $-swank =>
    swank_serve swank_serve_n swank_version;

lconstant swank_version = '0.1.0';

vars swank_evals = 0;

;;; --- streaming output ---------------------------------------------------

;;; Characters are buffered and shipped as swank/output notifications on
;;; a newline, at 400 characters, or when the stream changes -- so a
;;; long-running procedure's output reaches the editor while it runs,
;;; instead of arriving all at once when it finishes.
lvars out_conn = false, out_chars = [], out_n = 0, out_stream = 'out';

define lconstant flush_output();
    returnunless(out_n fi_> 0 and out_conn);
    jsonrpc_notify(out_conn, 'swank/output',
        jsonrpc_obj([% 'stream', out_stream,
                       'text', consstring(destlist(rev(out_chars))) %]));
    [] -> out_chars;
    0 -> out_n;
enddefine;

define lconstant collect(c, stream);
    unless stream = out_stream then
        flush_output();
        stream -> out_stream;
    endunless;
    conspair(c, out_chars) -> out_chars;
    out_n fi_+ 1 -> out_n;
    if c == `\n` or out_n fi_>= 400 then flush_output() endif;
enddefine;

define lconstant collect_out(c); collect(c, 'out') enddefine;
define lconstant collect_err(c); collect(c, 'err') enddefine;

;;; --- mishaps as data ----------------------------------------------------

;;; The frame walk sees the exception machinery above the user's code and
;;; the compiler below it; neither is any use to someone reading a
;;; backtrace, so both are trimmed off.
lconstant frame_top = 'sys_raise_exception';

lconstant frame_bottom =
    ['sysEXECUTE' 'pop11_exec_stmnt_seq_to' 'sysCOMPILE'
     'pop11_comp_stream' 'pop11_compile' 'eval_trapped' 'trycompile'
     'pop_setpop_compiler'];

define lconstant frame_name(p) -> s;
    lvars props = p and pdprops(p);
    (if props then props sys_>< nullstring else 'anonymous' endif) -> s;
enddefine;

define lconstant call_frames() -> l;
    lvars i, p, name, acc = [], started = false, all = [];
    ;;; snapshot first: consing inside the walk would add frames of its own
    for i from 0 to 40 do
        caller(i) -> p;
        quitunless(p);
        conspair(frame_name(p), all) -> all;
    endfor;
    rev(all) -> all;
    for name in all do
        if not(started) then
            if name = frame_top then true -> started endif;
            nextloop;
        endif;
        quitif(member(name, frame_bottom));
        conspair(name, acc) -> acc;
    endfor;
    ;;; no exception frame at all (an interrupt, say): keep what we have,
    ;;; minus the compiler tail
    unless started then
        [] -> acc;
        for name in all do
            quitif(member(name, frame_bottom));
            conspair(name, acc) -> acc;
        endfor;
    endunless;
    rev(acc) -> l;
enddefine;

;;; Results travel through file lexicals: exitfrom does not push a
;;; procedure's output locals (the trap pattern used throughout this
;;; tree -- see .claude/skills/pop11/bin/popsession).
lvars eval_ok = true, eval_interrupted = false,
     eval_message = false, eval_culprits = [], eval_frames = [];

define lconstant eval_trapped(code);
    dlocal prmishap =
        procedure(msg, culprits);
            lvars msg, culprits;
            false -> eval_ok;
            msg -> eval_message;
            culprits -> eval_culprits;
            call_frames() -> eval_frames;
            exitfrom(eval_trapped);
        endprocedure;
    ;;; Reached by SIGINT, and by any mishap that got past prmishap.
    dlocal interrupt =
        procedure();
            if eval_ok then
                false -> eval_ok;
                true -> eval_interrupted;
                call_frames() -> eval_frames;
            endif;
            exitfrom(eval_trapped);
        endprocedure;
    dlocal cucharout = collect_out, cucharerr = collect_err;
    pop11_compile(stringin(code));
enddefine;

;;; The user stack has no underflow guard, and exitfrom unwinds the call
;;; chain but not the stack: whatever the code left behind is reported as
;;; its values, and whatever it over-popped is made up again.
define lconstant take_values(base) -> vals;
    lvars x, n = stacklength() fi_- base, acc = [];
    if n fi_> 0 then
        for x in conslist(n) do
            conspair(x sys_>< nullstring, acc) -> acc;
        endfor;
    else
        until stacklength() == base do false enduntil;
    endif;
    consvector(destlist(rev(acc))) -> vals;
enddefine;

define lconstant do_eval(conn, code) -> result;
    lvars base, why = incomplete_code(code);

    if why then
        jsonrpc_obj([% 'ok', false, 'refused', why %]) -> result;
        return;
    endif;

    conn -> out_conn;
    'out' -> out_stream;
    [] -> out_chars;
    0 -> out_n;
    true -> eval_ok;
    false ->> eval_interrupted -> eval_message;
    [] ->> eval_culprits -> eval_frames;
    swank_evals fi_+ 1 -> swank_evals;

    stacklength() -> base;
    eval_trapped(code);
    lvars vals = take_values(base);
    flush_output();
    false -> out_conn;

    if eval_ok then
        jsonrpc_obj([% 'ok', true, 'values', vals %]) -> result;
    elseif eval_interrupted then
        jsonrpc_obj([% 'ok', false, 'interrupted', true,
                       'frames', consvector(destlist(eval_frames)) %]) -> result;
    else
        lvars c, cacc = [];
        for c in eval_culprits do
            conspair(c sys_>< nullstring, cacc) -> cacc;
        endfor;
        jsonrpc_obj([% 'ok', false,
            'mishap', jsonrpc_obj([%
                'message', eval_message sys_>< nullstring,
                'culprits', consvector(destlist(rev(cacc))),
                'frames', consvector(destlist(eval_frames)) %]) %]) -> result;
    endif;
enddefine;

;;; --- describing a name --------------------------------------------------

lvars desc_ok = true;

define lconstant describe_trapped(w) -> p;
    dlocal interrupt =
        procedure(); false -> desc_ok; exitfrom(describe_trapped) endprocedure;
    dlocal cucharerr = erase;
    jsonrpc_obj([]) -> p;
    identprops(w) sys_>< nullstring -> p('identprops');
    lvars v = sys_current_val(w);
    isprocedure(v) -> p('isProcedure');
    if isprocedure(v) then
        (pdprops(v) or false) sys_>< nullstring -> p('pdprops');
        pdnargs(v) -> p('nargs');
        (updater(v) and true) -> p('hasUpdater');
    else
        v sys_>< nullstring -> p('value');
        datakey(v) sys_>< nullstring -> p('datatype');
    endif;
enddefine;

define lconstant do_describe(name) -> result;
    lvars w = consword(name);
    true -> desc_ok;
    describe_trapped(w) -> result;
    name -> result('name');
    unless desc_ok and result('identprops') /= 'undef' then
        jsonrpc_obj([% 'name', name, 'defined', false %]) -> result;
        return;
    endunless;
    true -> result('defined');
enddefine;

;;; --- request handling ---------------------------------------------------

define lconstant handle(conn, msg);
    lvars method = msg('method'), id = msg('id'),
          params = msg('params') or jsonrpc_obj([]);

    if method = 'swank/connect' then
        jsonrpc_respond(conn, id, jsonrpc_obj([%
            'name', 'pop11-swank',
            'version', swank_version,
            'pid', poppid,
            'poplogVersion', popversion sys_>< nullstring,
            'features', {'eval' 'output' 'mishap' 'interrupt' 'describe'} %]));

    elseif method = 'swank/eval' then
        jsonrpc_respond(conn, id, do_eval(conn, params('code') or nullstring));

    elseif method = 'swank/describe' then
        jsonrpc_respond(conn, id, do_describe(params('name') or nullstring));

    elseif method = 'swank/state' then
        jsonrpc_respond(conn, id, jsonrpc_obj([%
            'evals', swank_evals,
            'heapBytes', popmemused,
            'pid', poppid %]));

    elseif method = 'swank/stop' then
        jsonrpc_respond(conn, id, jsonrpc_obj([% 'stopping', true %]));
        jsonrpc_stop(conn);

    elseif id then
        jsonrpc_error(conn, id, -32601, 'method not found: ' sys_>< method);
    endif;
enddefine;

;;; --- serving ------------------------------------------------------------

;;; Serve count connections (false = forever) on port, one at a time.
;;; Blocks; see SCOPE in the file header.
define swank_serve_n(port, count);
    lvars listener = jsonrpc_listen(port), conn, served = 0;
    npr('swank: listening on port ' sys_>< port sys_>< ' (pid '
        sys_>< poppid sys_>< ')');
    sysflush(popdevout);
    repeat
        jsonrpc_accept(listener, "header") -> conn;
        jsonrpc_serve(conn, handle);
        jsonrpc_close(conn);
        false -> out_conn;
        served fi_+ 1 -> served;
        quitif(count and served fi_>= count);
    endrepeat;
    jsonrpc_close(listener);
enddefine;

define swank_serve(port);
    swank_serve_n(port, false);
enddefine;

endsection;
