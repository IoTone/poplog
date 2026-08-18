/* pop/lsp/pop11_lsp.p -- a Language Server Protocol server, in Pop-11.

   Bindings P2 (2030plan 1.3): the tree-sitter grammar gives editors
   syntax colour; this gives them a live language brain.  Like the MCP
   server (pop/mcp/pop11_mcp.p) it does not shell out to anything: the
   server IS a Poplog session, so diagnostics come from the real
   compiler and hover text from the real HELP/REF corpus.

   Speaks LSP over stdio: Content-Length framed JSON-RPC 2.0.  The
   framing, dispatch and error handling are LIB * JSONRPC, shared with
   the MCP server; this file is the language brain on top of it.
   Launch via tools/pop11-lsp.

   v1 capabilities:
     textDocumentSync (full)   didOpen/didChange/didClose
     publishDiagnostics        the buffer is compiled with
                               pop_syntax_only = true -- the VM plants
                               nothing and nothing executes, but real
                               syntax mishaps surface with their line
     hover                     HELP/REF/TEACH entry for the word
     completion                dictionary words matching the prefix

   Caveat: pop_syntax_only stops execution of compiled code, but
   compile-time actions of syntax words still run -- notably `uses`
   will load the named library into the server (harmless, and it makes
   completions richer, but a `uses` of a slow library makes that
   check slow once).
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

;;; The one connection this process serves.  A stdio server has exactly
;;; one, so the reply helpers below close over it rather than threading
;;; it through every call site.
lvars conn = jsonrpc_stdio("header");

define lconstant respond(id, result);
    jsonrpc_respond(conn, id, result);
enddefine;

define lconstant respond_error(id, code, msg);
    jsonrpc_error(conn, id, code, msg);
enddefine;

define lconstant notify(method, params);
    jsonrpc_notify(conn, method, params);
enddefine;

;;; --- open documents -----------------------------------------------------

lconstant documents = newmapping([], 16, false, true);

;;; --- diagnostics --------------------------------------------------------

;;; results passed through file lexicals: exitfrom() does not push a
;;; procedure's output locals (the skill_run trap pattern)
lvars diag_msg = false, diag_inv = nullstring, diag_line = 0;

;;; poplinenum is not maintained for stringin streams, so count newlines
;;; ourselves; the itemiser's lookahead can overshoot by a line, which is
;;; close enough for a squiggle
lvars check_line = 1;

define lconstant counting_stringin(text) -> rep;
    lvars base = stringin(text);
    procedure();
        lvars c = base();
        if c == `\n` then check_line + 1 -> check_line endif;
        c
    endprocedure -> rep;
enddefine;

define lconstant check_trapped(text);
    dlocal interrupt =
        procedure();
            exitfrom(check_trapped);
        endprocedure;
    dlocal prmishap =
        procedure(msg, inv);
            lvars x, s = nullstring;
            msg -> diag_msg;
            for x in inv do
                s sys_>< (if s = nullstring then '' else ', ' endif)
                  sys_>< x -> s;
            endfor;
            s -> diag_inv;
            check_line -> diag_line;
        endprocedure;
    dlocal pop_syntax_only = true;
    ;;; discard anything the check writes
    dlocal cucharout = erase, cucharerr = erase;
    1 -> check_line;
    pop11_compile(counting_stringin(text));
enddefine;

define lconstant count_lines(text) -> n;
    lvars i;
    1 -> n;
    for i from 1 to length(text) do
        if text(i) == `\n` then n + 1 -> n endif;
    endfor;
enddefine;

define lconstant one_diag(line0, msg) -> d;
    lconstant BIGCOL = 400;
    jsonrpc_obj([% 'range',
                jsonrpc_obj([% 'start', jsonrpc_obj([% 'line', line0, 'character', 0 %]),
                         'end',   jsonrpc_obj([% 'line', line0, 'character', BIGCOL %]) %]),
             'severity', 1,
             'source', 'pop11',
             'message', msg %]) -> d;
enddefine;

define lconstant diagnostics_for(text) -> diags;
    lvars why, line0;
    consvector(0) -> diags;
    incomplete_code(text) -> why;
    if why then
        ;;; no line information from the scan: flag the last line
        consvector(one_diag(count_lines(text) - 1, why), 1) -> diags;
        return;
    endif;
    false -> diag_msg;
    check_trapped(text);
    if diag_msg then
        max(0, diag_line - 1) -> line0;
        consvector(one_diag(line0,
            diag_msg sys_>< (if diag_inv = nullstring then ''
                             else ' INVOLVING: ' sys_>< diag_inv endif)), 1)
            -> diags;
    endif;
enddefine;

define lconstant publish_diagnostics(uri, text);
    notify('textDocument/publishDiagnostics',
        jsonrpc_obj([% 'uri', uri, 'diagnostics', diagnostics_for(text) %]));
enddefine;

;;; --- text/position helpers ----------------------------------------------

;;; the (1-based) string indices of the (0-based) LSP line, or false
define lconstant line_bounds(text, line0) -> (lo, hi);
    lvars i, n = 0, len = length(text);
    false ->> lo -> hi;
    1 -> i;
    while n < line0 and i <= len do
        if text(i) == `\n` then n + 1 -> n endif;
        i + 1 -> i;
    endwhile;
    returnunless(n == line0);
    i -> lo;
    while i <= len and text(i) /== `\n` do i + 1 -> i endwhile;
    i - 1 -> hi;
enddefine;

define lconstant is_word_code(c);
    isalphacode(c) or isnumbercode(c) or c == `_`
enddefine;

;;; the identifier-shaped word around (line0, char0), or false
define lconstant word_at(text, line0, char0) -> w;
    lvars (lo, hi) = line_bounds(text, line0), p, a, b;
    false -> w;
    returnunless(lo);
    lo + char0 -> p;
    if p > hi + 1 then return endif;
    if p > hi or not(is_word_code(text(p))) then
        ;;; allow the cursor to sit just past the word
        returnif(p - 1 < lo or not(is_word_code(text(p - 1))));
        p - 1 -> p;
    endif;
    p -> a; p -> b;
    while a > lo and is_word_code(text(a - 1)) do a - 1 -> a endwhile;
    while b < hi and is_word_code(text(b + 1)) do b + 1 -> b endwhile;
    substring(a, b - a + 1, text) -> w;
enddefine;

;;; the word-prefix ending at (line0, char0) -> string (may be empty)
define lconstant prefix_at(text, line0, char0) -> pre;
    lvars (lo, hi) = line_bounds(text, line0), p, a;
    nullstring -> pre;
    returnunless(lo);
    lo + char0 - 1 -> p;            ;;; last char before the cursor
    if p > hi then hi -> p endif;
    returnif(p < lo or not(is_word_code(text(p))));
    p -> a;
    while a > lo and is_word_code(text(a - 1)) do a - 1 -> a endwhile;
    substring(a, p - a + 1, text) -> pre;
enddefine;

;;; --- hover: HELP/REF/TEACH lookup ---------------------------------------

lconstant doc_sections = ['help' 'ref' 'teach'];

define lconstant find_doc(name) -> path;
    lvars sec, try, dev;
    lvars docroot = systranslate('POP11_LSP_DOCROOT') or systranslate('usepop');
    false -> path;
    for sec in doc_sections do
        docroot dir_>< 'pop' dir_>< sec dir_>< name -> try;
        if (readable(try) ->> dev) then
            sysclose(dev);
            try -> path;
            return;
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
        conspair(copy(line), acc) -> acc;
    endrepeat;
    sysclose(dev);
    lvars l, out = '';
    for l in rev(acc) do out sys_>< l sys_>< '\n' -> out endfor;
    if n > maxlines then
        out sys_>< '...\n' -> out
    endif;
    out -> text;
enddefine;

define lconstant hover_for(word) -> result;
    lvars path = find_doc(word), text;
    json_null -> result;
    returnunless(path);
    read_doc(path, 40) -> text;
    jsonrpc_obj([% 'contents',
        jsonrpc_obj([% 'kind', 'markdown',
                 'value', '```\n' sys_>< text sys_>< '```' %]) %]) -> result;
enddefine;

;;; --- completion: dictionary words ---------------------------------------

lconstant COMPLETION_LIMIT = 200;

define lconstant completion_kind(w) -> kind;
    lvars props = identprops(w);
    if props == "syntax" or ispair(props) then
        14                              ;;; Keyword
    elseif props == "macro" then
        14
    elseif isinteger(props) then
        24                              ;;; Operator
    elseif isprocedure(sys_current_val(w)) then
        3                               ;;; Function
    else
        6                               ;;; Variable
    endif -> kind;
enddefine;

define lconstant completions_for(pre) -> result;
    lvars acc = [], n = 0;
    returnunless(length(pre) >= 2) (json_null -> result);
    appdic(
        procedure(w);
            lvars s = fast_word_string(w);
            returnif(n >= COMPLETION_LIMIT);
            returnunless(isstartstring(pre, s));
            returnif(identprops(w) == "undef");
            returnunless(length(s) > length(pre));
            conspair(jsonrpc_obj([% 'label', copy(s),
                             'kind', completion_kind(w) %]), acc) -> acc;
            n + 1 -> n;
        endprocedure);
    jsonrpc_obj([% 'isIncomplete', n >= COMPLETION_LIMIT,
             'items', consvector(destlist(rev(acc))) %]) -> result;
enddefine;

;;; --- request handling ---------------------------------------------------

define lconstant get_doc_and_pos(params) -> (uri, text, line0, char0);
    lvars pos = params('position');
    params('textDocument')('uri') -> uri;
    documents(uri) -> text;
    pos('line') -> line0;
    pos('character') -> char0;
enddefine;

define lconstant handle(msg);
    lvars method = msg('method'), id = msg('id'), params = msg('params');
    lvars td, uri, changes, text, line0, char0, w;

    if method = 'initialize' then
        respond(id, jsonrpc_obj([%
            'capabilities', jsonrpc_obj([%
                'textDocumentSync', 1,
                'hoverProvider', true,
                'completionProvider', jsonrpc_obj([% 'resolveProvider', false %])
            %]),
            'serverInfo', jsonrpc_obj([% 'name', 'pop11-lsp',
                                   'version', '0.1.0' %])
        %]));

    elseif method = 'initialized' then
        ;;; nothing

    elseif method = 'shutdown' then
        respond(id, json_null);

    elseif method = 'exit' then
        ;;; trapped diagnostic mishaps set pop_exit_ok false; an orderly
        ;;; exit must still report success to the client's process check
        true -> pop_exit_ok;
        jsonrpc_stop(conn);

    elseif method = 'textDocument/didOpen' then
        params('textDocument') -> td;
        td('uri') -> uri;
        td('text') -> documents(uri);
        publish_diagnostics(uri, documents(uri));

    elseif method = 'textDocument/didChange' then
        params('textDocument')('uri') -> uri;
        params('contentChanges') -> changes;
        if isvector(changes) and datalength(changes) > 0 then
            ;;; full sync: the last change carries the whole text
            subscrv(datalength(changes), changes)('text')
                -> documents(uri);
            publish_diagnostics(uri, documents(uri));
        endif;

    elseif method = 'textDocument/didClose' then
        params('textDocument')('uri') -> uri;
        false -> documents(uri);
        notify('textDocument/publishDiagnostics',
            jsonrpc_obj([% 'uri', uri, 'diagnostics', consvector(0) %]));

    elseif method = 'textDocument/hover' then
        get_doc_and_pos(params) -> (uri, text, line0, char0);
        text and word_at(text, line0, char0) -> w;
        respond(id, if w then hover_for(w) else json_null endif);

    elseif method = 'textDocument/completion' then
        get_doc_and_pos(params) -> (uri, text, line0, char0);
        respond(id,
            if text then completions_for(prefix_at(text, line0, char0))
            else json_null
            endif);

    elseif id /== false and not(isundef(id)) then
        ;;; a request we do not implement
        respond_error(id, -32601, 'method not found: ' sys_>< method);
    ;;; else: an unknown notification -- ignore
    endif;
enddefine;

;;; jsonrpc_serve traps a mishap in here, answers -32603 and carries on.
define lconstant dispatch(c, msg);
    handle(msg);
enddefine;

jsonrpc_serve(conn, dispatch);
;;; trapped diagnostic mishaps set pop_exit_ok false; EOF or an exit
;;; notification is an orderly shutdown and must exit 0
true -> pop_exit_ok;
