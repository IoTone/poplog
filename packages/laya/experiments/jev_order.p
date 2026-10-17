;;; E7: is the hosted Jev API order-sensitive, the way Laya is?
;;;
;;;     TYPESAFE_API_KEY=... JEV_OUT=.../e7-jev-order.json \
;;;         ./poplog ./target/pop/basepop11 packages/laya/experiments/jev_order.p
;;;
;;; This one talks to a paid external service.  It makes exactly 39 requests --
;;; printed as a plan before the first one -- and writes what came back.  Nothing
;;; else leaves the machine: the states below are invented support tickets, and
;;; the key is read from the environment and never written to the output.
;;;
;;; Rehearse it for free against a local Laya first; the protocol is the same:
;;;
;;;     uv run --project packages/laya python packages/laya/laya_serve.py --port 8799
;;;     JEV_BASE_URL=http://127.0.0.1:8799/v1 JEV_OUT=/tmp/dry.json \
;;;         ./poplog ./target/pop/basepop11 packages/laya/experiments/jev_order.p
;;;
;;; A loopback base url needs no key, and `ts_require_key` already knows that.
;;;
;;; Why it exists.  G3 and G4 (RESEARCH.md §2) were client bugs: ts_choice sent
;;; choice options, and ts_request sent questions, in hash order.  On Laya that
;;; changed answers -- §3.1 measured the pick changing in 5 of 6 orderings.  The
;;; client was fixed to send what was written, so the bug is gone either way.
;;; What stayed unknown is whether Jev, a different model behind a hosted API,
;;; was ever affected.  That is worth knowing because it says whether anyone's
;;; results from before the fix are suspect.
;;;
;;; Method.  Three parts, in this order, because the third is meaningless
;;; without the first:
;;;
;;;   CONTROL   the same request, byte for byte, three times per case.  A model
;;;             served behind an API may be nondeterministic -- batching,
;;;             sampling, a changing backend.  If repeats already disagree then
;;;             a difference between orderings proves nothing, and this
;;;             experiment can only report that much.
;;;   G3        all six orderings of three choice options, same text.
;;;   G4        all six orderings of three questions in one request.
;;;
;;; Lives here rather than under packages/typesafe because RESEARCH.md §6 is
;;; where this question is tracked, and the comparison conventions are here.
;;; What it tests is the typesafe client against the hosted model.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
uses fileutils;
uses typesafe;

;;; A base url given in the environment wins, so a dry run cannot reach the
;;; paid API by forgetting a flag.  Set after `uses`, which is what defines it.
lvars base = systranslate('JEV_BASE_URL');
if base and base /= '' then base -> ts_base_url endif;

;;; ----------------------------------------------------------------- helpers

;;; All permutations of 1..N, as a list of lists.  Index permutations rather
;;; than permuting the elements, so nothing depends on how two options compare.
define lconstant index_perms(n) -> ps;
    if n == 0 then
        [[]] -> ps;
    else
        lvars sub = index_perms(n - 1), p, i, j;
        [% for p in sub do
               for i from 1 to n do
                   [% for j from 1 to i - 1 do p(j) endfor;
                      n;
                      for j from i to length(p) do p(j) endfor %]
               endfor
           endfor %] -> ps;
    endif;
enddefine;

define lconstant apply_perm(perm, l) -> out;
    lvars i;
    [% for i in perm do l(i) endfor %] -> out;
enddefine;

define lconstant tag_of(perm) -> s;
    perm(1) sys_>< perm(2) sys_>< perm(3) -> s;
enddefine;

;;; One call, recorded.  A failure is written down rather than raised: losing
;;; the rows already paid for because the last one timed out would be silly.
define lconstant ask(state, questions) -> row;
    json_object() -> row;
    define dlocal prmishap(n, string);
        lvars n, string;
        if isstring(string) then erasenum(n); string -> row('error')
        else erasenum(n); 'mishap' -> row('error')
        endif;
        exitfrom(ask);
    enddefine;
    lvars answers = ts_eval(state, questions);
    answers        -> row('answers');
    ts_last_model  -> row('model');
    ts_last_usage  -> row('usage');
enddefine;

;;; ------------------------------------------------------------------- cases

lconstant TEAMS = [['billing'   'refunds, charges and invoices']
                   ['technical' 'bugs, crashes and outages']
                   ['sales'     'pricing, quotes and new seats']];

lconstant LEVELS = ['not urgent' 'somewhat urgent' 'very urgent'];

lconstant CASES = [
    ['dup_charge' 'I was billed twice this month. Please refund the duplicate charge.']
    ['crash'      'The app crashes every time I upload a photo from my phone.']
    ['pricing'    'Could you tell me what fifty additional seats would cost?']
];

define lconstant team_question(opts) -> q;
    [[team ^(ts_choice('Which team should handle this?', opts))]] -> q;
enddefine;

;;; The three questions of the G4 half, in written order.
define lconstant g4_questions() -> qs;
    [[urgency ^(ts_score('How urgent is this?', LEVELS))]
     [team    ^(ts_choice('Which team should handle this?', TEAMS))]
     [refund  ^(ts_noul('Is the customer asking for money back?',
                        'asking for a refund', 'not asking for a refund'))]] -> qs;
enddefine;

;;; -------------------------------------------------------------------- main

lvars out = json_object(), calls = 0;
lconstant planned = 3 * 3 + 3 * 6 + 2 * 6;

npr('E7: ' sys_>< planned sys_>< ' requests to ' sys_>< ts_base_url
    sys_>< ' as ' sys_>< ts_model);

;;; --- CONTROL: the same request three times, per case
lvars control = json_object(), c, rep;
for c in CASES do
    lvars rows = [], q = team_question(TEAMS);
    for rep from 1 to 3 do
        [^^rows ^(ask(c(2), q))] -> rows;
        calls + 1 -> calls;
    endfor;
    rows -> control(c(1));
endfor;
control -> out('control');
npr('control done (' sys_>< calls sys_>< ' calls)');

;;; --- G3: every ordering of the three options
lvars g3 = json_object(), perm;
for c in CASES do
    lvars rows = json_object();
    for perm in index_perms(3) do
        lvars opts = apply_perm(perm, TEAMS);
        lvars r = ask(c(2), team_question(opts));
        [% lvars o; for o in opts do o(1) endfor %] -> r('order');
        r -> rows(tag_of(perm));
        calls + 1 -> calls;
    endfor;
    rows -> g3(c(1));
endfor;
g3 -> out('g3_option_order');
npr('g3 done (' sys_>< calls sys_>< ' calls)');

;;; --- G4: every ordering of the three questions, first two cases
lvars g4 = json_object(), n;
for n from 1 to 2 do
    CASES(n) -> c;
    lvars rows = json_object();
    for perm in index_perms(3) do
        lvars qs = apply_perm(perm, g4_questions());
        lvars r = ask(c(2), qs);
        [% lvars q; for q in qs do q(1) sys_>< '' endfor %] -> r('order');
        r -> rows(tag_of(perm));
        calls + 1 -> calls;
    endfor;
    rows -> g4(c(1));
endfor;
g4 -> out('g4_question_order');
npr('g4 done (' sys_>< calls sys_>< ' calls)');

calls -> out('calls');
ts_base_url -> out('base_url');
ts_model -> out('model_asked');
string_to_file(json_generate(out), systranslate('JEV_OUT'));
npr('E7-DONE ' sys_>< calls sys_>< ' calls -> ' sys_>< systranslate('JEV_OUT'));
