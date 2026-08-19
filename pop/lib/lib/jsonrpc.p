/* --- JSON-RPC 2.0 transport ---------------------------------------------
 > File:            pop/lib/lib/jsonrpc.p
 > Purpose:         Framing, dispatch and error handling for JSON-RPC
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   HELP * JSONRPC
 > Related Files:   pop/mcp/pop11_mcp.p, pop/lsp/pop11_lsp.p,
 >                  LIB * JSON, LIB * UNIX_SOCKETS, LIB * INCOMPLETE_CODE,
 >                  tools/tests/test_jsonrpc.p
 >
 > Three servers in this tree speak JSON-RPC 2.0 and had each grown
 > their own copy of the same 80 lines: read a message, frame a reply,
 > trap a handler mishap, keep serving.  This is that code, once.
 >
 > Two framings, because the protocols that matter disagree:
 >
 >   "line"     one JSON value per line.  MCP over stdio.
 >   "header"   Content-Length: N CRLF CRLF then N bytes.  LSP.
 >
 > Two endpoints: stdio, and a TCP socket.  The socket half is what
 > lets a server sit inside a live session and answer an editor
 > asynchronously -- stdio has one channel and the reader owns it.
 >
 > A connection is opaque; hang your own per-connection data on
 > jsonrpc_state.  The read side is buffered, so a Content-Length body
 > costs one syscall rather than one per byte.
 */
compile_mode :pop11 +strict;

uses json;
uses unix_sockets;
include unix_sockets.ph;

section $-jsonrpc =>
    jsonrpc_stdio jsonrpc_wrap jsonrpc_listen jsonrpc_accept
    jsonrpc_connect jsonrpc_connect_n jsonrpc_connect_wait
    jsonrpc_close
    jsonrpc_device jsonrpc_state
    jsonrpc_read jsonrpc_write jsonrpc_obj
    jsonrpc_respond jsonrpc_error jsonrpc_notify
    jsonrpc_serve jsonrpc_stop;

lconstant BUFSIZE = 4096;

;;; jrc_dev is false for stdio, which reads with charin and writes with
;;; cucharout; anything else is a socket device read with sysread.
defclass jrconn {
    jrc_dev,
    jrc_framing,
    jrc_buf, jrc_pos, jrc_len,
    jrc_running,
    jrc_state
};

define lconstant new_conn(dev, framing) -> conn;
    unless framing == "line" or framing == "header" then
        mishap(framing, 1, 'JSONRPC: FRAMING MUST BE "line" OR "header"')
    endunless;
    consjrconn(dev, framing, inits(BUFSIZE), 1, 0, true, false) -> conn;
enddefine;

define jsonrpc_stdio(framing) -> conn;
    new_conn(false, framing) -> conn;
enddefine;

;;; Wrap a device you already have: a socket from elsewhere, one half of
;;; a sys_socket_pair, a pipe.
define jsonrpc_wrap(dev, framing) -> conn;
    new_conn(dev, framing) -> conn;
enddefine;

define lconstant set_reuseaddr(sock);
    dlocal interrupt =
        procedure(); exitfrom(set_reuseaddr) endprocedure;
    dlocal cucharerr = erase;
    true -> sys_socket_option(sock, SO_REUSEADDR);
enddefine;

;;; Bind and listen on port; returns the listening device, which is not
;;; a connection -- pass it to jsonrpc_accept.
define jsonrpc_listen(port) -> listener;
    unless isinteger(port) and port >= 0 then
        mishap(port, 1, 'JSONRPC: INTEGER PORT NEEDED')
    endunless;
    sys_socket(`i`, `S`, false) -> listener;
    ;;; Without SO_REUSEADDR the port stays unbindable for the length of
    ;;; TIME_WAIT after the last connection closes, which turns a server
    ;;; restart -- or a second test run -- into a spurious failure.  It
    ;;; is a nicety rather than a requirement though, and the option
    ;;; numbers are per-platform (see unix_sockets.ph), so a system that
    ;;; rejects it should still get its listener.
    set_reuseaddr(listener);
    [* ^port] -> sys_socket_name(listener, 5);
enddefine;

define jsonrpc_accept(listener, framing) -> conn;
    new_conn(sys_socket_accept(listener, false), framing) -> conn;
enddefine;

;;; do_connect in LIB * UNIX_SOCKETS is supposed to retry a refused
;;; connection at one-second intervals, five times by default.  It does
;;; not do so on Darwin -- a connect to a dead port fails instantly
;;; whatever the count (docs/bugs/darwin-connect-retry.md) -- so do not
;;; rely on it to cover a peer that is still starting.  Use
;;; jsonrpc_connect_wait for that.
define jsonrpc_connect_n(host, port, framing, retries) -> conn;
    lvars sock = sys_socket(`i`, `S`, false);
    [^host ^port] -> sys_socket_peername(sock, retries);
    new_conn(sock, framing) -> conn;
enddefine;

define jsonrpc_connect(host, port, framing) -> conn;
    jsonrpc_connect_n(host, port, framing, 5) -> conn;
enddefine;

;;; Connect, tolerating a peer that has not finished starting: returns
;;; false rather than mishapping if it is still refused after `secs'.
;;; The polling is here rather than left to do_connect because that
;;; retry is not portable (see above), and because a client would
;;; rather have false than an exception.
lvars wait_conn = false;

define lconstant connect_once(host, port, framing);
    dlocal interrupt =
        procedure(); false -> wait_conn; exitfrom(connect_once) endprocedure;
    dlocal cucharerr = erase;
    jsonrpc_connect_n(host, port, framing, 1) -> wait_conn;
enddefine;

define jsonrpc_connect_wait(host, port, framing, secs) -> conn;
    lvars deadline = sys_real_time() + secs;
    repeat
        false -> wait_conn;
        connect_once(host, port, framing);
        returnif(wait_conn) (wait_conn -> conn);
        returnif(sys_real_time() >= deadline) (false -> conn);
        syssleep(10);
    endrepeat;
enddefine;

define jsonrpc_close(conn);
    if isjrconn(conn) then
        if jrc_dev(conn) then sysclose(jrc_dev(conn)) endif;
        false -> jrc_dev(conn);
        false -> jrc_running(conn);
    else
        sysclose(conn);          ;;; a bare listener
    endif;
enddefine;

define jsonrpc_device(conn) -> dev;
    jrc_dev(conn) -> dev;
enddefine;

define jsonrpc_state(conn) -> s;
    jrc_state(conn) -> s;
enddefine;

define updaterof jsonrpc_state(s, conn);
    s -> jrc_state(conn);
enddefine;

define jsonrpc_stop(conn);
    false -> jrc_running(conn);
enddefine;

;;; --- reading ------------------------------------------------------------

define lconstant getc(conn) -> c;
    lvars dev = jrc_dev(conn), n;
    returnunless(dev) (charin() -> c);
    if jrc_pos(conn) fi_> jrc_len(conn) then
        sysread(dev, jrc_buf(conn), BUFSIZE) -> n;
        if n == 0 then termin -> c; return endif;
        n -> jrc_len(conn);
        1 -> jrc_pos(conn);
    endif;
    fast_subscrs(jrc_pos(conn), jrc_buf(conn)) -> c;
    jrc_pos(conn) fi_+ 1 -> jrc_pos(conn);
enddefine;

;;; One line, CR stripped, without its terminator; termin at EOF with
;;; nothing read.
define lconstant read_line(conn) -> line;
    lvars c, n = 0;
    repeat
        getc(conn) -> c;
        if c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop;
        endif;
        quitif(c == `\n`);
        unless c == `\r` then c; n fi_+ 1 -> n endunless;
    endrepeat;
    consstring(n) -> line;
enddefine;

;;; Exactly want bytes, or false if the stream ends first.
define lconstant read_n(conn, want) -> s;
    lvars i, c;
    inits(want) -> s;
    for i from 1 to want do
        getc(conn) -> c;
        if c == termin then false -> s; return endif;
        c -> fast_subscrs(i, s);
    endfor;
enddefine;

;;; Read one framed message body as a string; termin at EOF, false on a
;;; malformed frame.
define lconstant read_frame(conn) -> body;
    lvars line, len = false, i, c;
    if jrc_framing(conn) == "line" then
        repeat
            read_line(conn) -> line;
            returnif(line == termin) (termin -> body);
            returnunless(line = nullstring) (line -> body);
        endrepeat;
    else
        repeat
            read_line(conn) -> line;
            returnif(line == termin) (termin -> body);
            quitif(line = nullstring);
            if isstartstring('Content-Length:', line) then
                0 -> len;
                for i from 16 to length(line) do
                    line(i) -> c;
                    if isnumbercode(c) then len * 10 + (c fi_- `0`) -> len endif;
                endfor;
            endif;
        endrepeat;
        returnunless(len) (false -> body);
        read_n(conn, len) -> body;
        unless body then termin -> body endunless;
    endif;
enddefine;

;;; A parse mishap must not kill the server, and the mishap print must
;;; not land in the middle of the protocol stream.  Flat, with no output
;;; locals: exitfrom does not push a procedure's output locals.
lvars parsed = false;

define lconstant tryparse(text);
    dlocal interrupt =
        procedure(); false -> parsed; exitfrom(tryparse) endprocedure;
    dlocal cucharerr = erase;
    json_parse(text) -> parsed;
enddefine;

;;; -> the parsed message, termin at end of stream, false on a bad frame
;;; or unparseable JSON.
define jsonrpc_read(conn) -> msg;
    lvars body = read_frame(conn);
    returnif(body == termin) (termin -> msg);
    returnunless(body) (false -> msg);
    false -> parsed;
    tryparse(body);
    parsed -> msg;
enddefine;

;;; --- writing ------------------------------------------------------------

;;; The sysflush is load-bearing.  Poplog builds socket devices with the
;;; interactive flag set (Sys_cons_device in LIB * UNIX_SOCKETS), so
;;; syswrite holds back everything after the last newline until the
;;; device is flushed or closed.  A JSON body carries no trailing
;;; newline, so with header framing the peer would receive the
;;; Content-Length line and then block forever waiting for the body it
;;; was promised.  LIB * HTTP_SERVER only escapes this by closing the
;;; connection after every response; a long-lived one has to flush.
define lconstant put(conn, s);
    lvars dev = jrc_dev(conn);
    if dev then
        syswrite(dev, s, length(s));
        sysflush(dev);
    else
        ;;; Straight at the device, not through cucharout: charout's
        ;;; automatic wrapping at poplinewidth would insert newlines into
        ;;; a message and break both framings, and a server that dlocals
        ;;; cucharout to capture a user's output (as the MCP server does)
        ;;; would otherwise capture its own replies.
        syswrite(popdevout, s, length(s));
        sysflush(popdevout);
    endif;
enddefine;

define jsonrpc_write(conn, item);
    lvars s = json_generate(item);
    if jrc_framing(conn) == "line" then
        put(conn, s <> '\n');
    else
        ;;; Content-Length counts bytes, and a Pop-11 string is bytes.
        put(conn, 'Content-Length: ' sys_>< length(s) sys_>< '\r\n\r\n' <> s);
    endif;
enddefine;

;;; --- message builders ---------------------------------------------------

;;; jsonrpc_obj([% 'key', val, ... %]) -> property with string keys
define jsonrpc_obj(l) -> p;
    lvars k, v;
    newmapping([], 8, false, true) -> p;
    until l == [] do
        dest(l) -> (k, l);
        dest(l) -> (v, l);
        v -> p(k);
    enduntil;
enddefine;

define jsonrpc_respond(conn, id, result);
    jsonrpc_write(conn,
        jsonrpc_obj([% 'jsonrpc', '2.0', 'id', id, 'result', result %]));
enddefine;

define jsonrpc_error(conn, id, code, message);
    jsonrpc_write(conn,
        jsonrpc_obj([% 'jsonrpc', '2.0', 'id', id,
            'error', jsonrpc_obj([% 'code', code, 'message', message %]) %]));
enddefine;

define jsonrpc_notify(conn, method, params);
    jsonrpc_write(conn,
        jsonrpc_obj([% 'jsonrpc', '2.0', 'method', method,
                       'params', params %]));
enddefine;

;;; --- the serve loop -----------------------------------------------------

;;; Same flat-procedure trap: a bug in the SERVER must not end the
;;; process, so it is answered with a JSON-RPC internal error and the
;;; loop carries on.
lvars handled_ok = true;

define lconstant handle_trapped(handler, conn, msg);
    dlocal interrupt =
        procedure();
            false -> handled_ok;
            exitfrom(handle_trapped);
        endprocedure;
    handler(conn, msg);
enddefine;

;;; exitfrom unwinds the call chain but not the user stack, and the user
;;; stack has no underflow guard: a handler that died holding values, or
;;; one that popped more than it pushed, would poison the next message.
define lconstant restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

define lconstant safe_handle(handler, conn, msg);
    ;;; Arguments are already popped into the locals at this point, so
    ;;; stacklength() here IS the depth to restore to.
    lvars base = stacklength(), id;
    true -> handled_ok;
    handle_trapped(handler, conn, msg);
    restack(base);
    returnif(handled_ok);
    msg('id') -> id;
    if id and not(isundef(id)) and id /== json_null then
        jsonrpc_error(conn, id, -32603,
            'internal error handling ' sys_>< (msg('method') or 'request'));
    endif;
enddefine;

;;; Read and dispatch until the stream ends or jsonrpc_stop is called.
;;; handler(conn, msg) does the work; anything it leaves on the stack is
;;; discarded.  Notifications (no id) simply get no reply.
define jsonrpc_serve(conn, handler);
    lvars msg;
    true -> jrc_running(conn);
    repeat
        quitunless(jrc_running(conn));
        jsonrpc_read(conn) -> msg;
        quitif(msg == termin);
        if msg == false then
            jsonrpc_error(conn, json_null, -32700, 'parse error');
            nextloop;
        endif;
        nextunless(isproperty(msg));
        safe_handle(handler, conn, msg);
    endrepeat;
enddefine;

endsection;
