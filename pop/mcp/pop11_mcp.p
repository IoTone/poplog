/* pop/mcp/pop11_mcp.p -- an MCP (Model Context Protocol) server, in Pop-11.

   2030plan item 3.1: the pitch no other language can make is that an
   agent's helpers are compiled to NATIVE CODE in the live session.  So
   the server does not shell out to anything: it IS the session.  Each
   pop11_eval call incrementally compiles into this process's heap;
   defining a procedure once makes every later call microsecond-fast,
   and pop11_checkpoint can freeze the whole working state (native code
   included) into a saved image.

   Speaks MCP over stdio: newline-delimited JSON-RPC 2.0.  The framing,
   dispatch and error handling are LIB * JSONRPC, shared with the LSP
   server; this file is the tool set on top of it.  Launch via
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

;;; The launcher hands us the library directory of the checkout this
;;; script came from: the ENGINE root may be an older tarball install
;;; whose pop/lib predates the libraries below.  `uses' searches
;;; popuseslist, so extend that before the first one.
lvars lib_extra = systranslate('POP11_LIB_EXTRA');
if lib_extra then [^lib_extra ^^popuseslist] -> popuseslist endif;

uses json;
uses jsonrpc;
uses incomplete_code;

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

;;; The framing is safe from charout's automatic wrapping (LIB * JSONRPC
;;; writes straight at the device), but the wrapping would still break
;;; up a value inside a captured tool result at 70 columns.  Kill it.
false ->> poplinemax -> poplinewidth;

;;; --- the connection ---------------------------------------------------

;;; A stdio server has exactly one, so the reply helpers close over it
;;; rather than threading it through every call site.
lvars conn = jsonrpc_stdio("line");

define lconstant respond(id, result);
    jsonrpc_respond(conn, id, result);
enddefine;

define lconstant respond_error(id, code, msg);
    jsonrpc_error(conn, id, code, msg);
enddefine;

;;; --- evaluation with trap + output capture ------------------------------

vars mcp_evals = 0, mcp_restored = false;

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
    jsonrpc_obj([% 'type', 'object', 'properties', props, 'required', req %]) -> s;
enddefine;

define lconstant strprop(desc) -> p;
    jsonrpc_obj([% 'type', 'string', 'description', desc %]) -> p;
enddefine;

lconstant tool_list =
    {% jsonrpc_obj([% 'name', 'pop11_eval',
                'description',
                'Run Pop-11 code in the persistent live session. State and '
                sys_>< 'procedure definitions survive between calls, and every '
                sys_>< 'define is compiled to native machine code, so define '
                sys_>< 'helpers once and call them at microsecond cost. '
                sys_>< 'Mishaps (errors) are returned with their diagnostics; '
                sys_>< 'the session survives them.',
                'inputSchema',
                schema(jsonrpc_obj([% 'code', strprop('Pop-11 code to compile and run') %]),
                       {'code'}) %]),
       jsonrpc_obj([% 'name', 'pop11_help',
                'description',
                'Fetch Poplog documentation: HELP (usage), REF (reference) or '
                sys_>< 'TEACH (tutorials) file by name, e.g. name "json" or '
                sys_>< '"sys_file_match".',
                'inputSchema',
                schema(jsonrpc_obj([% 'name', strprop('documentation entry name'),
                               'section',
                               strprop('optional: help, ref or teach') %]),
                       {'name'}) %]),
       jsonrpc_obj([% 'name', 'pop11_checkpoint',
                'description',
                'Save the whole session (state + compiled procedures) to a '
                sys_>< 'Poplog image at PATH (~200 KB, restores in ~8 ms via '
                sys_>< 'pop11-mcp --restore PATH). If VERIFY is given it is '
                sys_>< 'evaluated first: a mishap or false result aborts the '
                sys_>< 'checkpoint, so you only persist validated state.',
                'inputSchema',
                schema(jsonrpc_obj([% 'path', strprop('absolute path for the .psv image'),
                               'verify',
                               strprop('optional gating expression') %]),
                       {'path'}) %]),
       jsonrpc_obj([% 'name', 'pop11_state',
                'description', 'Session facts: eval count, heap use, whether '
                sys_>< 'this session was restored from an image.',
                'inputSchema', schema(jsonrpc_obj([]), {}) %]),
       jsonrpc_obj([% 'name', 'pop11_play',
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
                schema(jsonrpc_obj([% 'story',
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

define lconstant handle(msg);
    lvars method = msg('method'), id = msg('id'), params = msg('params');
    lvars text, iserror, do_respond;

    if method = 'initialize' then
        respond(id, jsonrpc_obj([%
            'protocolVersion',
                if params and params('protocolVersion') then
                    params('protocolVersion')
                else '2024-11-05'
                endif,
            'capabilities', jsonrpc_obj([% 'tools', jsonrpc_obj([]) %]),
            'serverInfo',
                jsonrpc_obj([% 'name', 'pop11-mcp', 'version', '0.1.0' %]) %]));

    elseif method = 'ping' then
        respond(id, jsonrpc_obj([]));

    elseif method = 'tools/list' then
        respond(id, jsonrpc_obj([% 'tools', tool_list %]));

    elseif method = 'tools/call' then
        call_tool(params('name'),
                  params('arguments') or newmapping([], 4, false, true))
            -> (text, iserror, do_respond);
        if do_respond then
            respond(id, jsonrpc_obj([%
                'content', {% jsonrpc_obj([% 'type', 'text', 'text', text %]) %},
                'isError', iserror %]));
        endif;

    elseif isstartstring('notifications/', method) then
        ;;; notifications carry no id and get no response

    elseif id then
        respond_error(id, -32601, 'method not found: ' sys_>< method);
    endif;
enddefine;

;;; jsonrpc_serve traps a mishap in here, answers -32603 and carries on.
define lconstant dispatch(c, msg);
    handle(msg);
enddefine;

jsonrpc_serve(conn, dispatch);
;;; trapped eval mishaps set pop_exit_ok false; stdin EOF is an orderly
;;; shutdown and must exit 0
true -> pop_exit_ok;
