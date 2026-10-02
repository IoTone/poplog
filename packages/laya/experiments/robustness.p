;;; E2: does LIB LAYA hold up?  Many sequential calls, a malformed question, and the
;;; server killed in the middle of a call.  Run from an IoTone/poplog checkout root:
;;;
;;;     ROBUST_N=10000 ./poplog ./target/pop/basepop11 packages/laya/experiments/robustness.p

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;
uses laya;

false -> ts_api_key;
lvars n = strnumber(systranslate('ROBUST_N'));
lvars ok = 0, failures = 0, i, a;

define lconstant report(name, value);
    printf('%p: %p\n', [^name ^value]);
enddefine;

lvars q_choice = ts_choice('Which team should handle this?',
                           [[billing false] [technical false] [sales false]]);
lvars q_noul = ts_noul('Does the customer ask for money back?', false, false);
lvars texts = {'I was billed twice. Please refund the duplicate.'
               'The app crashes when I upload a photo.'
               'Can I get a quote for 50 seats?'};

;;; 1. n sequential calls on one child; every answer well-formed
laya_start();
lvars pid = laya_pid();
for i from 1 to n do
    ts_eval(subscrv((i mod 3) + 1, texts), [[d ^q_choice] [r ^q_noul]]) -> a;
    if member(a('d')('choice'), ['billing' 'technical' 'sales'])
    and a('r')('noul') >= 0 and a('r')('noul') <= 1 then
        ok + 1 -> ok
    else
        failures + 1 -> failures
    endif;
endfor;
report('sequential calls ok', ok);
report('sequential calls malformed', failures);
report('same child throughout', laya_pid() == pid);

;;; 2. a malformed question is a mishap, and the child keeps serving
lvars mishapped = false;
define lconstant try_bad();
    dlocal prmishap = procedure(m, l); true -> mishapped; exitfrom(try_bad) endprocedure;
    ts_eval('x', [[bad ^(ts_score('Empty rubric', []))]]) -> ;
enddefine;
try_bad();
report('malformed question mishaps', mishapped);
report('child survives a malformed question', laya_pid() == pid);

;;; 3. kill -9 the child mid-call: that call mishaps, the next starts a new child.
;;; A 64-question request on a long state keeps the child busy long enough for a
;;; kill scheduled 300 ms out to land mid-call.
lvars long = '' , k;
for k from 1 to 300 do long <> 'The customer reports duplicate billing again. ' -> long endfor;
lvars many = [% for k from 1 to 64 do [% 'q' sys_>< k, q_noul %] endfor %];
sysobey('(sleep 0.3; kill -9 ' sys_>< pid sys_>< ') &');
false -> mishapped;
define lconstant try_killed();
    dlocal prmishap = procedure(m, l); true -> mishapped; exitfrom(try_killed) endprocedure;
    repeat 50 times ts_eval(long, many) -> endrepeat;   ;;; ~seconds; the kill lands
enddefine;
try_killed();
report('killed mid-call mishaps', mishapped);
report('killed child forgotten', laya_running() == false);
ts_eval(subscrv(1, texts), [[d ^q_choice]]) -> a;
report('next call answers', a('d')('choice'));
report('with a new child', laya_pid() /== pid);
laya_stop();
npr('ROBUST-DONE');
