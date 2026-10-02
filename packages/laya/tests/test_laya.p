;;; test_laya.p -- LIB LAYA against a stand-in server: no model, no MLX.
;;;
;;;     sh tools/test-libs.sh packages/laya/tests/test_laya.p
;;;
;;; tests/fake_laya_server.py speaks the same protocol as
;;; `laya_serve.py --stdio`.  What it cannot check -- that real answers
;;; match Python's -- is experiments/parity.p.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;
uses laya;
uses poptest;

sysfileok('packages/laya/tests/fake_laya_server.py') -> laya_command;
false -> ts_api_key;            ;;; a local backend needs none

;;; ------------------------------------------------------------- startup

;;; by default the server is laya_serve.py, run by uv from this package
check('laya_home is absolute', isstartstring('/', laya_home) and true, true);
check('laya_home holds the server',
      sys_file_exists(laya_home dir_>< 'laya_serve.py'), true);
check('laya_home holds the uv project',
      sys_file_exists(laya_home dir_>< 'uv.lock'), true);

check('not running before first use', laya_running(), false);
check('health names the checkpoint',  laya_health()('model'),
      'fake/laya@0000000 float16');
check('running after first use',      laya_running(), true);
lvars first_pid = laya_pid();

;;; ------------------------------------------------- answers via ts_eval

lvars q_choice = ts_choice('Who?', [[billing false] [technical false]
                                     [sales false] [legal false] [hr false]]);
lvars q_noul  = ts_noul('Refund?', 'money back', false);
lvars q_score = ts_score('Urgent?', ['low' 'high']);

lvars a = ts_eval('I was billed twice.',
                  [[dept ^q_choice] [refund ^q_noul] [urgency ^q_score]]);
check('choice answer',  a('dept')('choice'), 'billing');
check('noul answer',    a('refund')('noul'), 0.75);
check('score answer',   a('urgency')('score'), 1.0);
check('options arrive in the order written',
      a('dept')('order'), {'billing' 'technical' 'sales' 'legal' 'hr'});
check('ts_last_model is the checkpoint', ts_last_model,
      'fake/laya@0000000 float16');
check('output tokens are zero', ts_last_usage('output_tokens'), 0);
check('same child serves every call', laya_pid(), first_pid);

;;; --------------------------------------------------------------- errors

;;; a rejected question is the caller's fault: mishap, but keep the child
check_mishaps('422 from the server mishaps',
              procedure; ts_eval('BAD', [[refund ^q_noul]]) -> ; endprocedure);
check('a 422 does not restart the child', laya_pid(), first_pid);

;;; the child dying mid-call: this call fails, the next one starts afresh
check_mishaps('a crash mid-call mishaps',
              procedure; ts_eval('CRASH', [[refund ^q_noul]]) -> ; endprocedure);
check('a crash forgets the child', laya_running(), false);
ts_eval('again', [[refund ^q_noul]]) -> a;
check('the next call restarts it', a('refund')('noul'), 0.75);
check('with a new process', laya_pid() /== first_pid, true);

;;; -------------------------------------------------------------- lifecycle

laya_stop();
check('stop stops it', laya_running(), false);

laya_uninstall();
check('uninstall restores http_request', ts_transport == http_request, true);
check('uninstall requires a key again',  ts_require_key, true);
laya_install();
check('install swaps the transport back', ts_transport == laya_transport, true);

;;; a command that does not exist fails at start, not on the first answer
'/nonexistent/laya_serve' -> laya_command;
check_mishaps('missing command mishaps', laya_start);
'no-such-laya-server-on-path' -> laya_command;
check_mishaps('command missing from PATH mishaps', laya_start);
check('and no child was started', laya_running(), false);

test_summary();
