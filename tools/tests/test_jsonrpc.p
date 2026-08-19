;;; test_jsonrpc.p — suite for LIB * JSONRPC and LIB * INCOMPLETE_CODE
;;; (run via tools/test-libs.sh)
;;;
;;; Both endpoints live in this one process.  A socketpair covers the
;;; line framing; a loopback listen/connect/accept covers the header
;;; framing and the real TCP path -- connect() completes into the
;;; listener's backlog, so the accept that follows it does not block.
uses poptest;
uses jsonrpc;
uses incomplete_code;
uses unix_sockets;

;;; --- structural precheck ------------------------------------------------

check('complete code', incomplete_code('npr(1);'), false);
check('unterminated string', incomplete_code('npr(\'oops);'),
      'unterminated string');
check('unclosed bracket', incomplete_code('npr((1);'), 'unclosed bracket');
check('unclosed comment', incomplete_code('/* forever'), 'unclosed /* comment');
check('nested comment closed',
      incomplete_code('/* a /* b */ c */ npr(1);'), false);
check('quote character literal',
      incomplete_code('if c == `\'` then npr(1) endif;'), false);
check('word quote needs no closer', incomplete_code('"alpha npr(1);'), false);
check('unfinished define allowed', incomplete_code('define f();'), false);
check('escaped quote in string',
      incomplete_code('npr(\'it\\\'s fine\');'), false);

;;; --- object builder -----------------------------------------------------

vars o = jsonrpc_obj([% 'a', 1, 'b', 'two' %]);
check('obj value', o('b'), 'two');
check('obj number', o('a'), 1);
check('obj missing', o('nope'), false);
check('obj empty', jsonrpc_obj([])('x'), false);

;;; --- line framing over a socketpair -------------------------------------

vars ca, cb;
sys_socket_pair(`u`, `S`, false) -> (ca, cb);
vars A = jsonrpc_wrap(ca, "line");
vars B = jsonrpc_wrap(cb, "line");

jsonrpc_write(A, jsonrpc_obj([% 'jsonrpc', '2.0', 'id', 1,
                                'method', 'ping' %]));
vars m = jsonrpc_read(B);
check('line: method', m('method'), 'ping');
check('line: id', m('id'), 1);

;;; two messages written back to back must both come out
jsonrpc_write(A, jsonrpc_obj([% 'id', 2 %]));
jsonrpc_write(A, jsonrpc_obj([% 'id', 3 %]));
check('line: first of two', jsonrpc_read(B)('id'), 2);
check('line: second of two', jsonrpc_read(B)('id'), 3);

;;; A body larger than the read buffer exercises the refill path.  Kept
;;; under 8k on purpose: both ends are this one process, so a write big
;;; enough to fill the socket buffer would block against a reader that
;;; cannot run until the write returns.
vars big = consstring(repeat 6000 times `x` endrepeat, 6000);
jsonrpc_write(A, jsonrpc_obj([% 'big', big %]));
check('line: body spanning two buffer fills',
      length(jsonrpc_read(B)('big')), 6000);

;;; --- helpers produce the right shapes -----------------------------------

jsonrpc_respond(A, 7, 'done');
jsonrpc_read(B) -> m;
check('respond jsonrpc', m('jsonrpc'), '2.0');
check('respond id', m('id'), 7);
check('respond result', m('result'), 'done');

jsonrpc_error(A, 8, -32601, 'method not found');
jsonrpc_read(B) -> m;
check('error code', m('error')('code'), -32601);
check('error message', m('error')('message'), 'method not found');

jsonrpc_notify(A, 'window/logMessage', jsonrpc_obj([% 'type', 3 %]));
jsonrpc_read(B) -> m;
check('notify method', m('method'), 'window/logMessage');
check('notify has no id', m('id'), false);

;;; --- bad input ----------------------------------------------------------

syswrite(ca, 'this is not json\n', 17);
check('parse error is false, not a mishap', jsonrpc_read(B), false);

;;; --- header framing over real TCP ---------------------------------------

;;; Retry on a fresh port: another test run, or anything else on this
;;; machine, may hold the one we picked.
vars port, listener = false, tries = 0;

define try_listen(p);
    dlocal interrupt = procedure(); exitfrom(try_listen) endprocedure;
    dlocal cucharerr = erase;
    jsonrpc_listen(p) -> listener;
enddefine;

until listener or tries > 20 do
    18900 + ((sys_real_time() + tries * 37) rem 400) -> port;
    tries + 1 -> tries;
    try_listen(port);
enduntil;
check_true('bound a listening port', listener and true);
vars client = jsonrpc_connect('localhost', port, "header");
vars server = jsonrpc_accept(listener, "header");

jsonrpc_write(client, jsonrpc_obj([% 'method', 'initialize', 'id', 1 %]));
jsonrpc_read(server) -> m;
check('header: method', m('method'), 'initialize');

jsonrpc_write(server, jsonrpc_obj([% 'big', big %]));
check('header: body spanning two buffer fills',
      length(jsonrpc_read(client)('big')), 6000);

;;; --- the serve loop -----------------------------------------------------

;;; A handler that answers pings, mishaps on 'boom', and deliberately
;;; leaves rubbish on the stack on 'litter'.
define test_handler(conn, msg);
    lvars method = msg('method');
    if method = 'ping' then
        jsonrpc_respond(conn, msg('id'), 'pong');
    elseif method = 'boom' then
        hd(3);                          ;;; LIST NEEDED
    elseif method = 'litter' then
        99, 98, 97;                     ;;; never consumed
        jsonrpc_respond(conn, msg('id'), 'littered');
    elseif method = 'stop' then
        jsonrpc_respond(conn, msg('id'), 'stopping');
        jsonrpc_stop(conn);
    endif;
enddefine;

;;; Write every request, then shut down only the writing half, so the
;;; server sees EOF while its replies can still reach us.
vars pa, pb;
sys_socket_pair(`u`, `S`, false) -> (pa, pb);
vars cl = jsonrpc_wrap(pa, "line");
vars sv = jsonrpc_wrap(pb, "line");

jsonrpc_write(cl, jsonrpc_obj([% 'method', 'ping', 'id', 1 %]));
jsonrpc_write(cl, jsonrpc_obj([% 'method', 'notify-only' %]));
jsonrpc_write(cl, jsonrpc_obj([% 'method', 'boom', 'id', 2 %]));
jsonrpc_write(cl, jsonrpc_obj([% 'method', 'litter', 'id', 3 %]));
jsonrpc_write(cl, jsonrpc_obj([% 'method', 'ping', 'id', 4 %]));
sys_socket_shutdown(pa, 1);

;;; NB the mishap block printed to stderr by the 'boom' request below is
;;; expected: the trap catches it and answers -32603, but the server
;;; still logs it, which is what a server should do.
;;;
;;; Measure into a variable -- calling stacklength() inside check's
;;; argument list would count check's own first argument.
vars depth = stacklength();
jsonrpc_serve(sv, test_handler);
vars after = stacklength();
check('serve leaves the stack as it found it', after, depth);
jsonrpc_close(sv);

jsonrpc_read(cl) -> m;
check('serve: answered ping', m('result'), 'pong');
jsonrpc_read(cl) -> m;
check('serve: mishap became an error reply', m('error')('code'), -32603);
check('serve: error names the method',
      issubstring('boom', m('error')('message')) and true, true);
jsonrpc_read(cl) -> m;
check('serve: survived the mishap', m('result'), 'littered');
jsonrpc_read(cl) -> m;
check('serve: still serving after that', m('result'), 'pong');
check('serve: notification drew no reply', jsonrpc_read(cl), termin);

;;; jsonrpc_stop ends the loop even with input still queued
vars qa, qb;
sys_socket_pair(`u`, `S`, false) -> (qa, qb);
vars qc = jsonrpc_wrap(qa, "line");
vars qs = jsonrpc_wrap(qb, "line");
jsonrpc_write(qc, jsonrpc_obj([% 'method', 'stop', 'id', 1 %]));
jsonrpc_write(qc, jsonrpc_obj([% 'method', 'ping', 'id', 2 %]));
jsonrpc_serve(qs, test_handler);
jsonrpc_close(qs);
jsonrpc_read(qc) -> m;
check('stop: answered the stop request', m('result'), 'stopping');
check('stop: read nothing after it', jsonrpc_read(qc), termin);

jsonrpc_close(cl);
jsonrpc_close(qc);
jsonrpc_close(client);
jsonrpc_close(server);
jsonrpc_close(listener);
jsonrpc_close(A);
jsonrpc_close(B);

test_summary();
