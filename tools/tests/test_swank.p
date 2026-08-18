;;; test_swank.p — suite for LIB * SWANK (run via tools/test-libs.sh)
;;;
;;; Launches tools/pop11-swank in a second Poplog process and drives it
;;; with LIB * JSONRPC as an editor would, which exercises the client
;;; half of the transport at the same time.  Run from the repo root.
uses poptest;
uses jsonrpc;
uses shell;

;;; This suite talks to another process, so its failure mode is a hang
;;; rather than a mishap.  Unbuffered output means the log shows how far
;;; it got instead of nothing at all.
false -> pop_buffer_charout;

lconstant port = 14500 + (sys_real_time() rem 300);

vars job = shell_bg('./tools/pop11-swank --port '
                    >< (port sys_>< nullstring) >< ' --once');

;;; --- connect, with the server still starting up -------------------------

;;; jsonrpc_connect_wait polls rather than trusting do_connect's own
;;; retry, which does not fire on Darwin.
vars conn = jsonrpc_connect_wait('localhost', port, "header", 30);
check_true('connected to the server', conn and true);

;;; Every reply may be preceded by any number of swank/output
;;; notifications; collect them so the tests can look at both.
vars nextid = 0, outputs = [];

define call(method, params) -> res;
    nextid + 1 -> nextid;
    [] -> outputs;
    jsonrpc_write(conn, jsonrpc_obj([% 'jsonrpc', '2.0', 'id', nextid,
                                       'method', method, 'params', params %]));
    repeat
        jsonrpc_read(conn) -> res;
        quitif(res == termin or res == false);
        quitunless(res('method'));
        outputs <> [% res('params') %] -> outputs;
    endrepeat;
enddefine;

define result_of(method, params) -> r;
    call(method, params)('result') -> r;
enddefine;

define evaluate(code) -> r;
    result_of('swank/eval', jsonrpc_obj([% 'code', code %])) -> r;
enddefine;

define output_text() -> s;
    lvars p;
    nullstring -> s;
    for p in outputs do s <> p('text') -> s endfor;
enddefine;

;;; --- who is answering ---------------------------------------------------

vars info = result_of('swank/connect', jsonrpc_obj([]));
check('server name', info('name'), 'pop11-swank');
check_true('reports a pid to signal', isinteger(info('pid')));
check_true('reports the interrupt feature',
           member('interrupt', [% explode(info('features')) %]) and true);

;;; --- evaluation ---------------------------------------------------------

vars r = evaluate('npr(19 + 23);');
check('eval succeeds', r('ok'), true);
check('output arrives as a notification', output_text(), '42\n');

;;; A bare expression leaves its value on the stack; `=>' prints instead.
evaluate('1 + 1;') -> r;
check('stack values are reported', r('values')(1), '2');
evaluate('3 + 4 =>') -> r;
check('=> prints rather than returning', output_text(), '** 7 \n');

;;; The session is one live heap: define here, call in a later request.
evaluate('define sq(n); lvars n; n * n enddefine;') -> r;
check('define succeeds', r('ok'), true);
evaluate('sq(12) =>') -> r;
check('session persists across requests', output_text(), '** 144 \n');

;;; Output must stream as it is produced, not arrive in one lump at the
;;; end -- that is the whole reason for a socket rather than stdio.
evaluate('lvars i; for i from 1 to 3 do npr(i) endfor;') -> r;
check('three lines arrive as three notifications', length(outputs), 3);

;;; --- mishaps as data ----------------------------------------------------

evaluate('hd(3);') -> r;
check('mishap is not ok', r('ok'), false);
check('mishap message', r('mishap')('message'), 'LIST NEEDED');
check('mishap culprits', r('mishap')('culprits')(1), '3');
check_true('mishap frames name the culprit procedure',
           member('hd', [% explode(r('mishap')('frames')) %]) and true);
check_true('mishap frames drop the exception machinery',
           not(member('sys_raise_exception',
                      [% explode(r('mishap')('frames')) %])));
evaluate('sq(5) =>') -> r;
check('session survived the mishap', output_text(), '** 25 \n');

;;; --- structurally incomplete code never reaches the compiler -------------

evaluate('npr(\'oops);') -> r;
check('incomplete code refused', r('refused'), 'unterminated string');
evaluate('sq(3) =>') -> r;
check('session survived the refusal', output_text(), '** 9 \n');

;;; --- interrupting a running evaluation ----------------------------------

;;; Nothing can arrive on this connection while the server is inside the
;;; user's loop, so the client signals the pid the handshake gave it.
;;; The engine delivers it at the next I_CHECK and the trap turns it into
;;; an ordinary result.
shell_bg('sleep 2; kill -INT ' >< (info('pid') sys_>< nullstring)) -> ;
evaluate('vars spin = 0; until false do spin + 1 -> spin enduntil;') -> r;
check('runaway loop was interrupted', r('interrupted'), true);
check('interrupt is not an ok result', r('ok'), false);
evaluate('spin > 0 =>') -> r;
check('session survived the interrupt', output_text(), '** <true> \n');

;;; --- describing a name --------------------------------------------------

vars d = result_of('swank/describe', jsonrpc_obj([% 'name', 'npr' %]));
check('describe: defined', d('defined'), true);
check('describe: is a procedure', d('isProcedure'), true);
check('describe: arity', d('nargs'), 1);
result_of('swank/describe', jsonrpc_obj([% 'name', 'sq' %])) -> d;
check('describe sees session definitions', d('isProcedure'), true);
result_of('swank/describe',
          jsonrpc_obj([% 'name', 'no_such_thing_at_all' %])) -> d;
check('describe: undefined name', d('defined'), false);

;;; --- state and shutdown -------------------------------------------------

vars st = result_of('swank/state', jsonrpc_obj([]));
check_true('state counts the evaluations', st('evals') > 10);
check('state agrees about the pid', st('pid'), info('pid'));

vars bad = call('swank/nonesuch', jsonrpc_obj([]));
check('unknown method', bad('error')('code'), -32601);

check('stop is acknowledged',
      result_of('swank/stop', jsonrpc_obj([]))('stopping'), true);
check('the connection ends after stop', jsonrpc_read(conn), termin);
jsonrpc_close(conn);

test_summary();
