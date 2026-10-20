;;; test_prolog_consult.p — what a CONSULTED FILE means (run via tools/test-libs.sh)
;;;
;;; The Prolog file compiler used to honour the interactive command words
;;; (ved, help, teach, ref, showlib, im, source, cd, pwd, pop11, bye) while
;;; reading a file, so a clause whose head used one of those functors was
;;; silently swallowed -- `help(a).` tried to open a HELP file instead.
;;; See docs/bugs/prolog-commands-swallow-clauses.md

uses poptest;
uses prolog;
uses define_prolog;

vars plog_taken = [];

;;; Pop-11 as a Prolog predicate, so a failure-driven loop can hand its
;;; solutions back here (HELP * DEFINE_PROLOG).
define :prolog t_take/1(x, contn);
    lvars x, contn;
    conspair(prolog_full_deref(x), plog_taken) -> plog_taken;
    chain(contn);
enddefine;

define solutions(goal) -> answers;
    lvars goal, answers;
    [] -> plog_taken;
    prolog_compile(stringin(':- (' <> goal <> ', t_take(X), fail ; true).'));
    rev(plog_taken) -> answers;
enddefine;

prolog_compile(discin('tools/tests/data/plog_commands.pl'));

;;; A command word as a clause head is an ordinary predicate.
check('help/1 is a predicate, not a HELP lookup', solutions('help(X)'), [a]);
check('ref/1', solutions('ref(X)'), [r]);
check('showlib/1', solutions('showlib(X)'), [s]);
check('pwd/1', solutions('pwd(X)'), [w]);
check('source/2 keeps both arguments', solutions('source(X, _)'), [x]);
check('cd/2 keeps both arguments', solutions('cd(_, X)'), [q]);

;;; And the clauses on either side of them survive, which is what made the
;;; old behaviour so quiet: the file still loaded, just not all of it.
check('clauses around them are unharmed', solutions('before(X)'), [1 2]);

;;; The command table itself is untouched -- these still work at the ?-
;;; prompt, which is the only place they were ever meant to.
check_true('the command table still has its entries',
           prolog_command("pwd") and prolog_command("help")
           and prolog_command("bye") and true);

test_summary();
