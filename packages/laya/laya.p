/* --- Laya typed decisions, local, behind the TypeSafe client -----------
 > File:            packages/laya/laya.p
 > Purpose:         Answer ts_eval locally with Laya on Apple Silicon (MLX)
 > Documentation:   packages/laya/README.md
 > Related Files:   packages/typesafe/typesafe.p, packages/laya/laya_serve.py,
 >                  LIB * RUN_UNIX_PROGRAM
 >
 > NOT part of the Poplog release; out-of-tree like LIB TYPESAFE.
 >
 > Laya (https://github.com/mizorewww/laya-mlx) takes the same request as
 > the hosted /v1/systemone -- state plus a map of noul/choice/score
 > questions -- and returns the same answers.  So nothing new is needed at
 > the call site: this library swaps ts_transport for one that talks to a
 > `laya_serve.py --stdio` child over a pipe, and ts_eval, ts_noul,
 > ts_choice and ts_score work unchanged.  The Python environment is this
 > package's own uv project (pyproject.toml, uv.lock), which pins laya-mlx
 > unmodified from PyPI.
 >
 > Why a child process and not HTTP: no port to choose, nothing listening
 > that another user could reach, and the child's lifetime is ours -- when
 > Poplog exits the pipe closes and the server sees end of input and exits.
 > Why not in-process: the model runs on Metal from Python, and a crash
 > there should not take the Poplog session with it.
 >
 > The protocol is JSON-RPC 2.0, one message per line.  An error carries
 > data.status, the HTTP status the same failure would get from the
 > server's HTTP transport, so typesafe's error handling applies as is.
 */
compile_mode :pop11 +strict;

uses typesafe;
uses json;
uses run_unix_program;

section $-laya
    ts_transport ts_require_key ts_model ts_timeout http_request
    json_parse json_generate
=>
    laya_home laya_command laya_model laya_router laya_dtype laya_extra_args
    laya_start_timeout
    laya_start laya_stop laya_running laya_pid laya_health
    laya_transport laya_install laya_uninstall
;

;;; ------------------------------------------------------------- settings

;;; This package's directory: laya_serve.py and the uv project that pins
;;; laya-mlx live here.  Taken from where this file was loaded, made absolute
;;; because the child may start after a change of directory; LAYA_HOME
;;; overrides it, for a copy of laya.p installed somewhere else.
define lconstant loaded_from() -> dir;
    false -> dir;
    returnunless(isstring(popfilename));
    sys_fname_path(popfilename) -> dir;
    unless isstartstring('/', dir) then current_directory dir_>< dir -> dir endunless;
enddefine;
vars laya_home = systranslate('LAYA_HOME') or loaded_from();

;;; false (the normal case): run laya_serve.py in laya_home's uv project.
;;; A command instead (LAYA_SERVER): run that with the same server arguments
;;; -- a stand-in server in tests, or a wrapper that adds timing.  Searched
;;; for on $PATH unless it starts with '/'.
vars laya_command    = systranslate('LAYA_SERVER') or false;
vars laya_model      = 'aac6fef/laya-mlx';
vars laya_router     = false;   ;;; true: route by language over all three
vars laya_dtype      = 'float16';
vars laya_extra_args = [];      ;;; e.g. ['--device' 'cpu']

;;; Seconds to wait for the server to load the model, or false for no limit.
;;; No limit by default: a first run downloads the checkpoint (about 0.9 GB),
;;; and its progress shows on stderr, so a slow start is visible, not silent.
;;; Each question is limited by ts_timeout instead (see laya_transport).
vars laya_start_timeout = false;

;;; ---------------------------------------------------------------- child

lvars indev = false, outdev = false, child = false, next_id = 0;

lconstant BUFSIZE = 65536;
lvars buf = inits(BUFSIZE), bufpos = 1, buflen = 0;

;;; sys_real_time() by which the current response must be complete, or false
lvars deadline = false;

define laya_running();
    child and true
enddefine;

define laya_pid();
    child
enddefine;

;;; Reap the child and forget it, so the next call starts a fresh one.
define lconstant forget();
    if indev then sysclose(indev) endif;
    if outdev then sysclose(outdev) endif;
    if child then sys_wait(child) -> (,) endif;
    false ->> indev ->> outdev -> child;
    1 -> bufpos; 0 -> buflen;
enddefine;

;;; A child that missed its deadline may be stuck anywhere, and may still
;;; answer later -- and a late answer would be read as the reply to the NEXT
;;; question.  So it is killed, not reused.
define lconstant abandon();
    if child then syskill(child) -> endif;
    forget();
enddefine;

;;; True once outdev has something to read (data, or end of file) -- false if
;;; the deadline passes first.  A select(2) via sys_device_wait, not a poll:
;;; while the model works we sleep in the kernel, and an answer is read the
;;; moment it arrives.  Only reached with the buffer empty, so a response
;;; already read costs nothing.  sys_real_time is in whole seconds, so a
;;; timeout of T fires after between T-1 and T seconds.
define lconstant response_ready() -> ok;
    lvars left, ready;
    returnunless(deadline) (true -> ok);
    repeat
        returnif(sys_input_waiting(outdev)) (true -> ok);
        deadline - sys_real_time() -> left;
        returnif(left <= 0) (false -> ok);
        sys_device_wait(outdev, [], [], intof(left * 1000000)) -> (ready, , );
        returnif(ready) (true -> ok);
    endrepeat;
enddefine;

;;; next byte; termin at end of file; "timeout" if the deadline passed
define lconstant getc() -> c;
    lvars n;
    if bufpos > buflen then
        unless response_ready() then "timeout" -> c; return endunless;
        sysread(outdev, buf, BUFSIZE) -> n;
        if n == 0 then termin -> c; return endif;
        n -> buflen;
        1 -> bufpos;
    endif;
    fast_subscrs(bufpos, buf) -> c;
    bufpos + 1 -> bufpos;
enddefine;

;;; One response line without its newline; termin if the child has gone,
;;; "timeout" if it did not finish the line in time.
define lconstant read_line() -> line;
    lvars c, n = 0;
    repeat
        getc() -> c;
        if c == "timeout" then
            erasenum(n);
            "timeout" -> line;
            return
        elseif c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop
        endif;
        quitif(c == `\n`);
        c; n + 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

;;; Send PARAMS_JSON (already-encoded JSON, or false for none) as METHOD
;;; and return the parsed response; termin if the child has gone, "timeout"
;;; if no complete response came within SECS seconds.  false or 0 mean no
;;; limit, as 0 does for http_request (libcurl), which this stands in for.
define lconstant call(method, params_json, secs) -> msg;
    dlocal deadline = secs and secs > 0 and sys_real_time() + secs;
    lvars line, id;
    next_id + 1 ->> next_id -> id;
    lvars req = '{"jsonrpc":"2.0","id":' sys_>< id
                <> ',"method":"' <> method <> '"'
                <> (if params_json then ',"params":' <> params_json else '' endif)
                <> '}\n';
    syswrite(indev, req, length(req));
    ;;; load-bearing, as in LIB * JSONRPC: an unflushed pipe device holds
    ;;; the request back and both sides wait forever
    sysflush(indev);
    read_line() -> line;
    if line == termin or line == "timeout" then line -> msg; return endif;
    json_parse(line) -> msg;
    unless msg('id') = id then
        mishap(line, 1, 'laya: response id does not match request ' sys_>< id)
    endunless;
enddefine;

;;; Make laya_home/.venv match uv.lock exactly (--frozen: never re-resolve on
;;; the way to answering a question).  A no-op taking milliseconds when it
;;; already does; the first time, it creates the environment.
;;;
;;; Then the server is started with that environment's python directly, NOT
;;; with `uv run`: uv run does not exec, it keeps itself as the parent of
;;; python.  The child -- laya_pid(), the process whose pipes we hold and
;;; whose death we detect -- would be uv, and signals to it (kill -9 in
;;; particular) would leave the real server running and answering.
define lconstant sync_environment();
    lvars status;
    unless laya_home and sys_file_exists(laya_home dir_>< 'pyproject.toml') then
        mishap(laya_home, 1,
               'laya: no pyproject.toml in laya_home -- set LAYA_HOME to packages/laya')
    endunless;
    unless sys_search_unix_path('uv', systranslate('PATH') or '') then
        mishap(0, 'laya: uv not found on $PATH -- see https://docs.astral.sh/uv/')
    endunless;
    run_unix_program('uv', ['sync' '--project' ^laya_home '--frozen' '--quiet'],
                     false, false, false, true) -> (, , , status, );
    unless status == 0 then
        mishap(laya_home, 1, 'laya: uv sync failed (see its output above)')
    endunless;
enddefine;

define laya_start();
    returnif(child);
    lvars program, args,
        server_args =
            [% '--stdio', '--dtype', laya_dtype,
               if laya_router then '--router' else '--model', laya_model endif,
               explode(laya_extra_args) %];
    if laya_command then
        laya_command -> program;
        server_args -> args;
    else
        sync_environment();
        laya_home dir_>< '.venv/bin/python' -> program;
        [% laya_home dir_>< 'laya_serve.py', explode(server_args) %] -> args;
    endif;
    ;;; Find the program before forking.  If exec fails in the child,
    ;;; run_unix_program's child mishaps -- and a mishap handler further up
    ;;; (any caller's, a test's) can catch it IN THE CHILD, which then carries
    ;;; on as a second copy of this Poplog, reading the same input.
    unless (if isstartstring('/', program) then sys_file_exists(program)
            else sys_search_unix_path(program, systranslate('PATH') or '')
            endif) then
        mishap(program, 1, 'laya: server command not found')
    endunless;
    ;;; stderr is inherited (false): load progress, warnings and tracebacks
    ;;; go where the user can see them, and never into the protocol
    run_unix_program(program, args, true, true, false, false)
        -> (indev, outdev, , , child);
    ;;; The first answer waits for the model to load -- seconds, more on a
    ;;; first download -- so ask for it here, where a failure to start is
    ;;; reported as one rather than as a failed question.
    lvars msg = call('health', false, laya_start_timeout);
    if msg == termin then
        forget();
        mishap(program, 1,
               'laya: server exited while starting (see its output above)')
    elseif msg == "timeout" then
        abandon();
        mishap(laya_start_timeout, 1,
               'laya: server not ready within laya_start_timeout seconds')
    endif;
enddefine;

define laya_stop();
    forget();
enddefine;

;;; property with 'status' and 'model' -- the checkpoint that will answer
define laya_health() -> p;
    laya_start();
    lvars msg = call('health', false, ts_timeout);
    if msg == termin then
        forget();
        mishap(0, 'laya: server exited')
    elseif msg == "timeout" then
        abandon();
        mishap(ts_timeout, 1, 'laya: no health answer within ts_timeout seconds')
    endif;
    msg('result') -> p;
enddefine;

;;; ------------------------------------------------------------ transport
;;; http_request's signature, so it can stand in for it as ts_transport:
;;;     (method, url, body, headers, timeout) -> (body, headers, status)
;;; METHOD, URL and HEADERS mean nothing to a pipe.  TIMEOUT (ts_eval passes
;;; ts_timeout) bounds each call, in seconds; false or 0 mean no limit.

define laya_transport(method, url, body, headers, timeout)
                                            -> (rbody, rheaders, status);
    lvars msg, err;
    newmapping([], 4, false, true) -> rheaders;
    laya_start();
    call('systemone', body, timeout) -> msg;
    if msg == "timeout" then
        ;;; Killed rather than waited for (see abandon).  504, like a gateway
        ;;; timeout: ts_eval does not retry it, and the next call starts a
        ;;; fresh child -- paying the model load again, which is the price of
        ;;; never reading a stale answer.
        abandon();
        'laya server did not answer within ' sys_>< timeout sys_>< ' seconds' -> rbody;
        504 -> status;
    elseif msg == termin then
        ;;; The child died mid-call.  Forget it so the next call starts a
        ;;; new one, and fail this call cleanly: 503 is not retried by
        ;;; ts_eval, because a model that crashes on a request will very
        ;;; likely crash on it again.
        forget();
        'laya server exited during the request (see its output above)'
            -> rbody;
        503 -> status;
    elseif msg('error') ->> err then
        err('message') -> rbody;
        (err('data') and err('data')('status')) or 500 -> status;
    else
        json_generate(msg('result')) -> rbody;
        200 -> status;
    endif;
enddefine;

;;; Point ts_eval at the local model, or back at the hosted API.
define laya_install();
    laya_transport -> ts_transport;
    false -> ts_require_key;
    'laya' -> ts_model;     ;;; informational: the child chose its checkpoint
enddefine;

define laya_uninstall();
    http_request -> ts_transport;
    true -> ts_require_key;
    'jev-latest' -> ts_model;
enddefine;

laya_install();

endsection;
