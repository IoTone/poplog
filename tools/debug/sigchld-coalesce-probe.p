;;; sigchld-coalesce-probe.p -- do several children dying at once all get
;;; reaped?  Run it directly, not as a suite:
;;;
;;;     ./poplog target/pop/basepop11 tools/debug/sigchld-coalesce-probe.p
;;;
;;; SIG_CHILD does not queue: one delivery can stand for any number of
;;; deaths.  Get_os_process_trap (pop/src/os_process.p) reaps the first
;;; terminated entry on os_process_list, runs its ast and returns, so a
;;; single call per signal leaves the rest unreaped with no further signal
;;; coming.  Their asts never run, is_dead never goes true, and anything
;;; waiting on them waits for good: sys_wait parks, and the read_pipe loop
;;; in sys_popen spins at 100% CPU because the `false` that ends it is only
;;; reachable once the child's status has arrived.
;;;
;;; THIS IS NOT IN tools/tests BECAUSE IT STILL FAILS ABOUT ONE RUN IN
;;; FIVE WITH THE signals.p DRAIN IN PLACE.  Draining per signal is
;;; necessary and not sufficient: ten children dying together lost one to
;;; four asts on EVERY round before the fix (about 2 per round) and now
;;; lose about one per 25 rounds, so a second hole remains and a suite
;;; built on this would be a flaky gate.  Promote it to tools/tests once
;;; the rate is zero.
;;;
;;; See docs/bugs/syssleep-expired-timer-spin.md.

uses poptest;

vars fired = [];
define note(pid, status);
    lvars pid, status;
    [^^fired ^pid] -> fired
enddefine;

define forked_deaths(n) -> lost;
    lvars n, i, pid, pids = [], lost, waited = 0;

    [] -> fired;
    for i from 1 to n do
        sys_fork(false, note) -> pid;
        unless pid then
            ;;; the child: sleep so that all of them wake and exit
            ;;; together, which is what makes the deliveries coalesce
            syssleep(30);
            sysexit()
        endunless;
        [^^pids ^pid] -> pids
    endfor;

    ;;; check points for the traps to run, with a bound so a regression
    ;;; fails the check instead of hanging the suite
    until length(fired) == n or waited >= 2000 do
        syssleep(10);
        waited + 10 -> waited
    enduntil;

    n - length(fired) -> lost;
    unless lost == 0 then
        printf(';;; forked %p\n;;; reaped %p\n', [% pids, fired %])
    endunless
enddefine;

;;; one child is the case that always worked, and is here so a failure
;;; says whether reaping broke altogether or only coalescing
check('one child is reaped', forked_deaths(1), 0);

;;; The loss is a race, so one round of ten can come back clean on a
;;; broken engine -- it did, while this test was being written.  Sum
;;; several rounds: unfixed, every round lost one to four.
define total_lost(rounds, n) -> lost;
    lvars rounds, n, i;
    0 -> lost;
    for i from 1 to rounds do
        lost + forked_deaths(n) -> lost
    endfor
enddefine;

check('six rounds of ten simultaneous children lose none',
      total_lost(6, 10), 0);

test_summary();
