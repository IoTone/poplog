;;; test_sigchld_coalesce.p — several children dying at once must all be
;;; reaped (run via tools/test-libs.sh)
;;;
;;; SIG_CHILD does not queue: one delivery can stand for any number of
;;; deaths, and the kernel keeps at most one pending.
;;; Get_os_process_trap (pop/src/os_process.p) reaps the first terminated
;;; entry on os_process_list, runs its ast and returns -- one child per
;;; call -- and the dispatch in signals.p used to call it exactly once per
;;; signal.  The rest stayed unreaped with no further signal coming: their
;;; asts never ran, is_dead never went true, and anything waiting on them
;;; waited for good.  sys_wait parks (the symptom #47 bounded without
;;; curing) and sys_popen's read_pipe loop spins at 100% CPU, because the
;;; false that ends popen_drain is only reachable once the child's status
;;; has arrived.
;;;
;;; Unfixed, this missed an ast in 17 of 30 rounds (25 in all); fixed,
;;; 0 of 30.  Ten rounds therefore catch a regression with better than
;;; 99.9% probability.  See docs/bugs/sigchld-coalesce-lost-child-status.md.
;;;
;;; NOTE ON THE SHAPE OF THIS TEST.  Each ast writes its own preallocated
;;; slot: no consing, no shared accumulator.  The obvious version --
;;; `[^^fired ^pid] -> fired` in the ast -- is itself racy, because
;;; allocation is a check point and asts run at check points, so an ast
;;; nested inside that cons loses the outer update.  That cost an hour of
;;; chasing a hole in the engine that was really a hole in the probe.

;;; test-timeout: 120

uses poptest;

lconstant n = 10, rounds = 10;

vars pidv = initv(n), gotv = initv(n);

define note(pid, status);
    lvars pid, status, i;
    for i from 1 to n do
        if fast_subscrv(i, pidv) == pid then
            1 -> fast_subscrv(i, gotv);
            return
        endif
    endfor
enddefine;

;;; fork n children that sleep and exit together, so their deaths
;;; coalesce, and report how many asts never ran
define do_round(k) -> missed;
    lvars k, i, pid, waited = 0, missed = 0;
    for i from 1 to n do
        0 ->> fast_subscrv(i, gotv) -> fast_subscrv(i, pidv)
    endfor;
    ;;; slots past k stay marked done, so only the k forked count
    for i from k + 1 to n do
        1 -> fast_subscrv(i, gotv)
    endfor;
    for i from 1 to k do
        sys_fork(false, note) -> pid;
        unless pid then
            syssleep(30);
            sysexit()
        endunless;
        pid -> fast_subscrv(i, pidv)
    endfor;
    ;;; bounded, so a regression fails the check instead of hanging
    repeat
        0 -> missed;
        for i from 1 to n do
            if fast_subscrv(i, gotv) == 0 then missed + 1 -> missed endif
        endfor;
        quitif(missed == 0 or waited >= 500);
        syssleep(10);
        waited + 10 -> waited
    endrepeat
enddefine;

define total_missed(k) -> missed;
    lvars k, i, m;
    0 -> missed;
    for i from 1 to k do
        do_round(n) -> m;
        missed + m -> missed;
        unless m == 0 then
            printf(';;; round %p: %p ast(s) never ran\n', [% i, m %])
        endunless
    endfor
enddefine;

;;; one child at a time is the case that always worked, so a failure here
;;; says reaping broke altogether rather than only the coalesced case
check('a single child is reaped', do_round(1), 0);

check('ten rounds of ten simultaneous children lose no ast',
      total_missed(rounds), 0);

test_summary();
