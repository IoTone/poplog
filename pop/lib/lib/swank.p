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
 >   swank/inspect     a value's class, printing and parts, with handles
 >                     for drilling further in without re-evaluating
 >   swank/complete    live dictionary words matching a prefix
 >   swank/trace       trace or untrace a procedure by name
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

;;; --- stack discipline ---------------------------------------------------

;;; exitfrom unwinds the call chain but not the user stack, and a mishap
;;; has usually pushed the operands of the raise before it fires.  Every
;;; trap in this file has to put the stack back afterwards, or the junk
;;; surfaces as the arguments of whatever is called next -- which shows
;;; up as an absurd mishap a long way from the cause.
define lconstant restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

;;; --- printing values for a client ---------------------------------------

lconstant PRINT_LIMIT = 240;

;;; Bounded on two axes: nesting, because a cyclic or merely deep
;;; structure would otherwise print forever, and length, because the
;;; client is showing this in one line of a buffer.
define lconstant printed(x) -> s;
    dlocal pop_pr_level = 4, pop_pr_quotes = true;
    x sys_>< nullstring -> s;
    if length(s) fi_> PRINT_LIMIT then
        substring(1, PRINT_LIMIT, s) <> '...' -> s;
    endif;
enddefine;

define lconstant class_name(x) -> s;
    class_dataword(datakey(x)) sys_>< nullstring -> s;
enddefine;

;;; --- inspecting a live value --------------------------------------------

;;; Handles let the client drill into a structure without the server
;;; having to re-evaluate anything.  They are reset whenever a new
;;; inspection starts from an expression, which bounds the table to one
;;; object graph.
lvars handles = false, nhandles = 0;

define lconstant reset_handles();
    newmapping([], 64, false, false) -> handles;
    0 -> nhandles;
enddefine;
reset_handles();

define lconstant new_handle(x) -> h;
    nhandles fi_+ 1 -> nhandles;
    x -> handles(nhandles);
    nhandles -> h;
enddefine;

;;; datalist explodes anything compound and mishaps on everything else,
;;; which is as good a definition of "has parts" as Pop-11 offers.
lvars parts_ok = true, parts_list = [];

define lconstant parts_of(x);
    dlocal interrupt =
        procedure(); false -> parts_ok; exitfrom(parts_of) endprocedure;
    dlocal cucharerr = erase;
    datalist(x) -> parts_list;
enddefine;

define lconstant describe_value(x) -> p;
    lvars part, acc = [], n = 0;
    jsonrpc_obj([]) -> p;
    class_name(x) -> p('class');
    printed(x) -> p('printed');
    lvars base = stacklength();
    true -> parts_ok;
    [] -> parts_list;
    parts_of(x);
    restack(base);
    if isprocedure(x) then
        (pdprops(x) or false) sys_>< nullstring -> p('pdprops');
        pdnargs(x) -> p('nargs');
    endif;
    if parts_ok then
        for part in parts_list do
            n fi_+ 1 -> n;
            conspair(jsonrpc_obj([%
                'index', n,
                'printed', printed(part),
                'class', class_name(part),
                'handle', new_handle(part) %]), acc) -> acc;
        endfor;
        consvector(destlist(rev(acc))) -> p('parts');
    else
        {} -> p('parts');
    endif;
    ;;; Field NAMES are not recoverable from a class key -- class_spec
    ;;; gives types, not names -- so parts are indexed, not labelled.
    n -> p('partCount');
enddefine;

lvars value_ok = true, value_got = false;

define lconstant value_trapped(expr);
    dlocal prmishap =
        procedure(msg, culprits);
            lvars msg, culprits;
            false -> value_ok;
            msg -> value_got;
            exitfrom(value_trapped);
        endprocedure;
    dlocal interrupt =
        procedure(); false -> value_ok; exitfrom(value_trapped) endprocedure;
    dlocal cucharout = erase, cucharerr = erase;
    lvars base = stacklength();
    pop11_compile(stringin(expr));
    if stacklength() fi_> base then
        -> value_got;
        until stacklength() == base do erase() enduntil;
    else
        false -> value_ok;
        'the expression left no value on the stack' -> value_got;
    endif;
enddefine;

define lconstant do_inspect(params) -> result;
    lvars h = params('handle'), expr = params('expr'), x;
    if h then
        handles(h) -> x;
        unless x or h fi_<= nhandles then
            jsonrpc_obj([% 'ok', false,
                           'error', 'no such handle' %]) -> result;
            return;
        endunless;
    else
        returnunless(expr)
            (jsonrpc_obj([% 'ok', false,
                            'error', 'expr or handle needed' %]) -> result);
        reset_handles();
        true -> value_ok;
        false -> value_got;
        lvars base = stacklength();
        value_trapped(expr);
        restack(base);
        unless value_ok then
            jsonrpc_obj([% 'ok', false,
                'error', value_got sys_>< nullstring %]) -> result;
            return;
        endunless;
        value_got -> x;
    endif;
    describe_value(x) -> result;
    true -> result('ok');
    if h then h else new_handle(x) endif -> result('handle');
enddefine;

;;; --- tracing ------------------------------------------------------------

;;; trace and untrace are syntax words taking identifiers, so the name
;;; goes back through the compiler rather than through a procedure call.
;;; (`wanted' rather than the obvious `on', which is a loop keyword.)
define lconstant do_trace(name, wanted) -> result;
    lvars base = stacklength();
    true -> value_ok;
    value_trapped((if wanted then 'trace ' else 'untrace ' endif)
                  sys_>< name sys_>< '; 0;');
    restack(base);
    jsonrpc_obj([% 'ok', value_ok, 'name', name, 'traced', wanted %]) -> result;
enddefine;

;;; --- completion over the live dictionary --------------------------------

lconstant COMPLETION_LIMIT = 200;

define lconstant do_complete(prefix) -> result;
    lvars acc = [], n = 0;
    returnunless(length(prefix) fi_>= 1)
        (jsonrpc_obj([% 'items', {} %]) -> result);
    appdic(
        procedure(w);
            lvars w, s = fast_word_string(w);
            returnif(n fi_>= COMPLETION_LIMIT);
            returnunless(isstartstring(prefix, s));
            returnif(identprops(w) == "undef");
            conspair(copy(s), acc) -> acc;
            n fi_+ 1 -> n;
        endprocedure);
    jsonrpc_obj([% 'items', consvector(destlist(rev(acc))),
                   'truncated', n fi_>= COMPLETION_LIMIT %]) -> result;
enddefine;

;;; --- where a name comes from --------------------------------------------

;;; An autoloadable library is a file named after the identifier, which
;;; is exactly what VED's ENTER showlib relies on.  A procedure defined
;;; inside a larger file has no such trail -- the client tracks those
;;; itself, since it is the one that compiled them.
lconstant library_dirs =
    ['$popautolib/' '$popliblib/' '$popvedlib/' '$poplocalauto/'
     '$popdatalib/'];

lconstant doc_sections = ['help' 'ref' 'teach'];

;;; The engine root can be a tarball install, which ships pop/lib but no
;;; documentation, while the launcher was run from a checkout that has
;;; both.  Same split the LSP server handles with POP11_LSP_DOCROOT.
define lconstant search_dirs() -> dirs;
    lvars extra = systranslate('POP11_LIB_EXTRA');
    if extra then [^extra ^^library_dirs] else library_dirs endif -> dirs;
enddefine;

define lconstant docroot() -> d;
    (systranslate('POP11_SWANK_DOCROOT') or systranslate('usepop')) -> d;
enddefine;

define lconstant find_file(dirs, name, suffix) -> path;
    lvars dir, try, dev;
    false -> path;
    for dir in dirs do
        sysfileok(dir sys_>< name sys_>< suffix) -> try;
        if (readable(try) ->> dev) then
            sysclose(dev);
            try -> path;
            return;
        endif;
    endfor;
enddefine;

define lconstant doc_file(name) -> path;
    lvars sec, dirs = [];
    for sec in doc_sections do
        conspair(docroot() dir_>< 'pop' dir_>< sec dir_>< nullstring,
                 dirs) -> dirs;
    endfor;
    find_file(rev(dirs), name, nullstring) -> path;
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
        find_file(search_dirs(), name, '.p') -> result('sourceFile');
        doc_file(name) -> result('docFile');
        return;
    endunless;
    true -> result('defined');
    find_file(search_dirs(), name, '.p') -> result('sourceFile');
    doc_file(name) -> result('docFile');
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
            'features', {'eval' 'output' 'mishap' 'interrupt' 'describe'
                         'inspect' 'complete' 'trace'} %]));

    elseif method = 'swank/eval' then
        jsonrpc_respond(conn, id, do_eval(conn, params('code') or nullstring));

    elseif method = 'swank/describe' then
        jsonrpc_respond(conn, id, do_describe(params('name') or nullstring));

    elseif method = 'swank/inspect' then
        jsonrpc_respond(conn, id, do_inspect(params));

    elseif method = 'swank/complete' then
        jsonrpc_respond(conn, id,
                        do_complete(params('prefix') or nullstring));

    elseif method = 'swank/trace' then
        jsonrpc_respond(conn, id,
            do_trace(params('name') or nullstring,
                     params('untrace') /== true));

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
