/* pop/mcp/pop11_mcp.p -- an MCP (Model Context Protocol) server, in Pop-11.

   2030plan item 3.1: the pitch no other language can make is that an
   agent's helpers are compiled to NATIVE CODE in the live session.  So
   the server does not shell out to anything: it IS the session.  Each
   pop11_eval call incrementally compiles into this process's heap;
   defining a procedure once makes every later call microsecond-fast,
   and pop11_checkpoint can freeze the whole working state (native code
   included) into a saved image.

   Speaks MCP over stdio: newline-delimited JSON-RPC 2.0, parsed and
   generated with lib json (itself pure Pop-11).  Launch via
   tools/pop11-mcp, which resolves the Poplog tree the same way the
   pop11 skill does.

   Tools exposed:
     pop11_eval        run Pop-11 code in the persistent session
     pop11_help        look up HELP/REF/TEACH documentation
     pop11_checkpoint  save the session image, optionally gated on a
                       verify expression (mishap/false => no image)
     pop11_state       session facts (evals, memory, restored?)
     pop11_play        play interactive fiction on the Pop-11 Z-machine

   A mishap in user code is caught (the skill_run trap pattern): the
   diagnostics come back in the tool result with isError true, and the
   server survives.
*/

compile_mode :pop11 +strict;

uses json;

;;; LIB ZMACHINE (the Z-machine interpreter, for the pop11_play tool) ships
;;; with Poplog, but this server may be running against an older installed
;;; tree that predates it.  Load it if it is there and simply do without
;;; the tool if it is not -- a missing game must not cost an agent its
;;; whole session.
vars zmachine_ok = false;
vars procedure (zstart, zturn, zplaying);

define lconstant load_zmachine();
    dlocal interrupt = procedure(); exitfrom(load_zmachine) endprocedure;
    pop11_compile(stringin(
        'uses zmachine_play; zplay_start -> zstart; zplay_turn -> zturn; '
            <> 'zplay_playing -> zplaying;'));
    true -> zmachine_ok;
enddefine;
load_zmachine();

;;; JSON-RPC framing is one message per line: charout's automatic line
;;; wrapping (poplinemax) would split messages, so kill it outright.
false ->> poplinemax -> poplinewidth;

;;; --- stdio ------------------------------------------------------------

;;; Read one LF-terminated line from stdin -> string, or termin at EOF.
define lconstant read_line() -> line;
    lvars c, acc = [], n = 0;
    repeat
        charin() -> c;
        if c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop;
        endif;
        quitif(c == `\n`);
        conspair(c, acc) -> acc;
        n + 1 -> n;
    endrepeat;
    consstring(destlist(rev(acc))) -> line;
enddefine;

define lconstant send_json(item);
    lvars s = json_generate(item), i;
    for i from 1 to length(s) do cucharout(s(i)) endfor;
    cucharout(`\n`);
    sysflush(popdevout);
enddefine;

;;; --- small json builders ------------------------------------------------

;;; mkobj([% key1, val1, key2, val2, ... %]) -> property   (string keys)
define lconstant mkobj(l) -> p;
    lvars k, v;
    newmapping([], 8, false, true) -> p;
    until l == [] do
        dest(l) -> (k, l);
        dest(l) -> (v, l);
        v -> p(k);
    enduntil;
enddefine;

;;; --- evaluation with trap + output capture ------------------------------

vars mcp_evals = 0, mcp_restored = false;

;;; The compiler recovers cleanly from mishaps INSIDE a complete stream,
;;; but a stream that ENDS mid-token or mid-bracket (unclosed string,
;;; paren, comment) corrupts shared itemiser state beyond what the
;;; interrupt trap can repair.  So structurally incomplete code is
;;; refused before it reaches the compiler.  -> false, or a description
;;; of what is unclosed.
define lconstant incomplete_code(s) -> why;
    lvars i = 1, len = length(s), c, depth = 0, cdepth, j;
    false -> why;
    while i <= len do
        s(i) -> c;
        if c == `;` and i + 2 <= len
        and s(i+1) == `;` and s(i+2) == `;` then
            ;;; line comment: to end of line
            while i <= len and s(i) /== `\n` do i + 1 -> i endwhile;
        elseif c == `/` and i < len and s(i+1) == `*` then
            ;;; nesting block comment
            1 -> cdepth; i + 2 -> i;
            while i <= len and cdepth > 0 do
                if s(i) == `/` and i < len and s(i+1) == `*` then
                    cdepth + 1 -> cdepth; i + 2 -> i;
                elseif s(i) == `*` and i < len and s(i+1) == `/` then
                    cdepth - 1 -> cdepth; i + 2 -> i;
                else
                    i + 1 -> i;
                endif;
            endwhile;
            if cdepth > 0 then 'unclosed /* comment' -> why; return endif;
            nextloop;
        elseif c == `'` then
            i + 1 -> i;
            while i <= len and s(i) /== `'` do
                if s(i) == `\\` then i + 1 -> i endif;
                i + 1 -> i;
            endwhile;
            if i > len then 'unterminated string' -> why; return endif;
        elseif c == `"` then
            i + 1 -> i;
            while i <= len and s(i) /== `"` and s(i) /== `\n` do
                i + 1 -> i
            endwhile;
            ;;; unclosed-at-delimiter word shorthand is legal; no check
        elseif c == `\`` then
            ;;; char constant: closed within the line, or legacy 1-unit form
            false -> j;
            lvars k = i + 1;
            while k <= len and s(k) /== `\n` and k <= i + 8 do
                if s(k) == `\`` then k -> j; quitloop endif;
                k + 1 -> k;
            endwhile;
            if j then j -> i else i + 1 -> i endif;
        elseif c == `(` or c == `[` or c == `{` then
            depth + 1 -> depth;
        elseif c == `)` or c == `]` or c == `}` then
            depth - 1 -> depth;
        endif;
        i + 1 -> i;
    endwhile;
    if depth > 0 then 'unclosed bracket' -> why endif;
enddefine;

lvars eval_ok = true;   ;;; set false by the mishap trap

;;; The skill_run trap pattern, in a flat top-level procedure with no
;;; output locals: exitfrom() does NOT push a procedure's output locals,
;;; so results are passed through eval_ok instead.
define lconstant compile_trapped(code);
    dlocal interrupt =
        procedure();
            false -> eval_ok;
            exitfrom(compile_trapped);
        endprocedure;
    pop11_compile(stringin(code));
enddefine;

define lconstant mcp_eval(code) -> (ok, out);
    lvars chars = [], sl, x;
    lvars collect =
        procedure(c); conspair(c, chars) -> chars endprocedure;
    dlocal cucharout = collect, cucharerr = collect;

    true -> ok;
    nullstring -> out;
    mcp_evals + 1 -> mcp_evals;

    lvars why = incomplete_code(code);
    if why then
        false -> ok;
        'refused: code is structurally incomplete (' sys_>< why
            sys_>< ') — it would corrupt the session compiler' -> out;
        return;
    endif;

    stacklength() -> sl;
    true -> eval_ok;
    compile_trapped(code);
    eval_ok -> ok;

    ;;; whatever the code left on the stack: print it => style (so the
    ;;; agent sees the values) and keep the server's stack clean.
    if stacklength() fi_> sl then
        lvars extras = conslist(stacklength() fi_- sl);
        for x in extras do
            appdata('** ' sys_>< x sys_>< '\n', collect);
        endfor;
    endif;
    consstring(destlist(rev(chars))) -> out;
enddefine;

;;; --- documentation lookup -----------------------------------------------

lconstant doc_sections = ['help' 'ref' 'teach'];

define lconstant find_doc(name, want_sec) -> (path, found);
    lvars sec, try, dev;
    lvars docroot = systranslate('POP11_MCP_DOCROOT') or systranslate('usepop');
    false ->> path -> found;
    for sec in
        if want_sec then [^want_sec] else doc_sections endif
    do
        docroot dir_>< 'pop' dir_>< sec dir_>< name -> try;
        if (readable(try) ->> dev) then
            sysclose(dev);
            try -> path; true -> found; return;
        endif;
    endfor;
enddefine;

define lconstant read_doc(path, maxlines) -> text;
    lvars dev = sysopen(path, 0, "line");
    lvars rep = line_repeater(dev, inits(4096)), line, acc = [], n = 0;
    repeat
        rep() -> line;
        quitif(line == termin);
        n + 1 -> n;
        quitif(n > maxlines);
        conspair(line, acc) -> acc;
    endrepeat;
    sysclose(dev);
    lvars l, out = '';
    for l in rev(acc) do out sys_>< l sys_>< '\n' -> out endfor;
    if n > maxlines then
        out sys_>< '... (truncated at ' sys_>< maxlines sys_>< ' lines)\n' -> out
    endif;
    out -> text;
enddefine;

;;; --- the tool table ------------------------------------------------------

define lconstant schema(props, req) -> s;
    mkobj([% 'type', 'object', 'properties', props, 'required', req %]) -> s;
enddefine;

define lconstant strprop(desc) -> p;
    mkobj([% 'type', 'string', 'description', desc %]) -> p;
enddefine;

lconstant tool_list =
    {% mkobj([% 'name', 'pop11_eval',
                'description',
                'Run Pop-11 code in the persistent live session. State and '
                sys_>< 'procedure definitions survive between calls, and every '
                sys_>< 'define is compiled to native machine code, so define '
                sys_>< 'helpers once and call them at microsecond cost. '
                sys_>< 'Mishaps (errors) are returned with their diagnostics; '
                sys_>< 'the session survives them.',
                'inputSchema',
                schema(mkobj([% 'code', strprop('Pop-11 code to compile and run') %]),
                       {'code'}) %]),
       mkobj([% 'name', 'pop11_help',
                'description',
                'Fetch Poplog documentation: HELP (usage), REF (reference) or '
                sys_>< 'TEACH (tutorials) file by name, e.g. name "json" or '
                sys_>< '"sys_file_match".',
                'inputSchema',
                schema(mkobj([% 'name', strprop('documentation entry name'),
                               'section',
                               strprop('optional: help, ref or teach') %]),
                       {'name'}) %]),
       mkobj([% 'name', 'pop11_checkpoint',
                'description',
                'Save the whole session (state + compiled procedures) to a '
                sys_>< 'Poplog image at PATH (~200 KB, restores in ~8 ms via '
                sys_>< 'pop11-mcp --restore PATH). If VERIFY is given it is '
                sys_>< 'evaluated first: a mishap or false result aborts the '
                sys_>< 'checkpoint, so you only persist validated state.',
                'inputSchema',
                schema(mkobj([% 'path', strprop('absolute path for the .psv image'),
                               'verify',
                               strprop('optional gating expression') %]),
                       {'path'}) %]),
       mkobj([% 'name', 'pop11_state',
                'description', 'Session facts: eval count, heap use, whether '
                sys_>< 'this session was restored from an image.',
                'inputSchema', schema(mkobj([]), {}) %]),
       mkobj([% 'name', 'pop11_play',
                'description',
                'Play interactive fiction. Poplog ships a Z-machine written '
                sys_>< 'in Pop-11 (LIB ZMACHINE), so Infocom-format story '
                sys_>< 'files run in this same session. Give STORY to begin a '
                sys_>< 'game (a .z3 or .z5 path; examples/games/cave.z3 ships '
                sys_>< 'with Poplog) or COMMAND to take one turn in the game '
                sys_>< 'already running. Returns exactly what the game '
                sys_>< 'printed. The game keeps its state between calls, so '
                sys_>< 'play it as you would at a terminal.',
                'inputSchema',
                schema(mkobj([% 'story',
                               strprop('path to a story file, to start a game'),
                               'command',
                               strprop('one command for the running game, '
                                   sys_>< 'e.g. "take lamp"') %]),
                       {}) %])
    %};

;;; --- tool dispatch -------------------------------------------------------

;;; -> (text, iserror, respond)  — respond=false means "send nothing"
;;; (the stale in-flight request of a freshly RESTORED image).
define lconstant call_tool(name, args) -> (text, iserror, respond);
    lvars ok, out, path, found, sec;
    '' -> text; false -> iserror; true -> respond;

    if name = 'pop11_eval' then
        mcp_eval(args('code')) -> (ok, out);
        out -> text;
        not(ok) -> iserror;

    elseif name = 'pop11_help' then
        args('name') -> out;
        args('section') -> sec;
        find_doc(out, sec) -> (path, found);
        if found then
            read_doc(path, 400) -> text;
        else
            'no HELP/REF/TEACH entry named "' sys_>< out sys_>< '"' -> text;
            true -> iserror;
        endif;

    elseif name = 'pop11_play' then
        ;;; the Z-machine lives in the same session, so a game survives
        ;;; between tool calls exactly as a compiled procedure does
        lvars story = args('story'), cmd = args('command');
        if not(zmachine_ok) then
            'LIB ZMACHINE is not available in this Poplog tree.' -> text;
            true -> iserror;
        elseif story and not(isundef(story)) then
            zstart(story) -> text
        elseif cmd and not(isundef(cmd)) then
            unless zplaying() then
                'No game is running. Call again with "story" to start one.'
                    -> text;
                true -> iserror;
            else
                zturn(cmd) -> text
            endunless
        else
            'Give either "story" (to start a game) or "command" (to play the '
                sys_>< 'running one).' -> text;
            true -> iserror;
        endif;

    elseif name = 'pop11_checkpoint' then
        args('path') -> path;
        if args('verify') then
            mcp_eval('unless (' sys_>< args('verify')
                     sys_>< ') then mishap(\'verify gate returned false\', []) endunless;')
                -> (ok, out);
            unless ok then
                'verify gate failed; no image written:\n' sys_>< out -> text;
                true -> iserror;
                return;
            endunless;
        endif;
        sysgarbage();
        if syssave(path) then
            ;;; we are a RESTORED image resuming inside an old request:
            ;;; do not answer it — fall back to the main loop quietly.
            true -> mcp_restored;
            false -> respond;
        else
            'checkpoint saved: ' sys_>< path -> text;
        endif;

    elseif name = 'pop11_state' then
        'evals: ' sys_>< mcp_evals
            sys_>< '\nheap bytes used: ' sys_>< popmemused
            sys_>< '\nrestored from image: ' sys_>< mcp_restored
            sys_>< '\npop_internal_version: ' sys_>< pop_internal_version
            -> text;

    else
        'unknown tool: ' sys_>< name -> text;
        true -> iserror;
    endif;
enddefine;

;;; --- protocol loop -------------------------------------------------------

define lconstant respond(id, result);
    send_json(mkobj([% 'jsonrpc', '2.0', 'id', id, 'result', result %]));
enddefine;

define lconstant respond_error(id, code, msg);
    send_json(mkobj([% 'jsonrpc', '2.0', 'id', id,
                       'error', mkobj([% 'code', code, 'message', msg %]) %]));
enddefine;

define lconstant handle(msg);
    lvars method = msg('method'), id = msg('id'), params = msg('params');
    lvars text, iserror, do_respond;

    if method = 'initialize' then
        respond(id, mkobj([%
            'protocolVersion',
                if params and params('protocolVersion') then
                    params('protocolVersion')
                else '2024-11-05'
                endif,
            'capabilities', mkobj([% 'tools', mkobj([]) %]),
            'serverInfo',
                mkobj([% 'name', 'pop11-mcp', 'version', '0.1.0' %]) %]));

    elseif method = 'ping' then
        respond(id, mkobj([]));

    elseif method = 'tools/list' then
        respond(id, mkobj([% 'tools', tool_list %]));

    elseif method = 'tools/call' then
        call_tool(params('name'),
                  params('arguments') or newmapping([], 4, false, true))
            -> (text, iserror, do_respond);
        if do_respond then
            respond(id, mkobj([%
                'content', {% mkobj([% 'type', 'text', 'text', text %]) %},
                'isError', iserror %]));
        endif;

    elseif isstartstring('notifications/', method) then
        ;;; notifications carry no id and get no response

    elseif id then
        respond_error(id, -32601, 'method not found: ' sys_>< method);
    endif;
enddefine;

lvars parse_msg = false;

;;; flat + no output locals, same reason as compile_trapped
define lconstant tryparse(line);
    dlocal interrupt =
        procedure(); false -> parse_msg; exitfrom(tryparse) endprocedure;
    dlocal cucharerr = erase;    ;;; swallow the mishap print
    json_parse(line) -> parse_msg;
enddefine;

;;; A bug in the SERVER itself must not kill the process: trap, answer
;;; with a JSON-RPC internal error, keep serving.
define lconstant safe_handle(msg);
    dlocal interrupt =
        procedure();
            respond_error(msg('id') or json_null, -32603, 'internal error');
            exitfrom(safe_handle);
        endprocedure;
    handle(msg);
enddefine;

define lconstant serve();
    lvars line, msg;
    repeat
        read_line() -> line;
        quitif(line == termin);
        nextif(line = nullstring);

        tryparse(line);
        parse_msg -> msg;
        if msg then
            safe_handle(msg);
        else
            respond_error(json_null, -32700, 'parse error');
        endif;
    endrepeat;
    ;;; trapped user mishaps must not surface as a non-zero exit
    true -> pop_exit_ok;
enddefine;

serve();
;;; trapped eval mishaps set pop_exit_ok false; stdin EOF is an orderly
;;; shutdown and must exit 0
true -> pop_exit_ok;
