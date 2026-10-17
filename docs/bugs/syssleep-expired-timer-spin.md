# syssleep spins at 100% CPU on an already-expired real timer

**Status:** mechanism identified from one captured stack; fix not written.
**Platforms:** all three hosted CI platforms (x86_64 Linux, aarch64 Linux,
macOS arm64).  Never reproduced on a developer machine.
**Rate:** 6 hangs in 21 release-gate legs, about 30% per leg.
**Found:** 2026-10-17, by `.github/workflows/skill-release.yml` running all
16 library suites on hosted runners for the first time.  The Jenkins gate
ran 2 suites, so it could not have seen this.

## What it looks like

A library suite stops making progress after its visible checks have
passed, and `tools/test-libs.sh` reports:

    FAIL  test_sysexecute_or_exit  (timed out after 120s)

The suite differs by platform -- `test_sysexecute_or_exit` on x86_64
Linux, `test_http_server` on aarch64 Linux and macOS arm64 -- and the
reported output is truncated mid-line, because the watchdog SIGKILLs the
process group while it still has buffered output.

It is not a slow suite.  Raising `TEST_TIMEOUT` from 120s to 600s changes
only the number in the message: the same suites wedge for the full ten
minutes.

## The captured state

`tools/debug/hang-watch.sh`, run beside an unmodified
`sh tools/test-libs.sh`, caught `test_sysexecute_or_exit` on x86_64 Linux
151 seconds in:

    --- children and grandchildren ---
    (none)
    --- wchan / syscall ---
    0
    running
    --- signals and state ---
    State:  R (running)
    SigPnd: 0000000000000000
    SigBlk: 0000000000002000      <- bit 13 = signal 14 = SIGALRM
    --- native backtrace ---
    #0  __setitimer (which=ITIMER_REAL, new_value=0xda4940 <itv>, ...)
    #1  next_timer (timerp=0x5db690 <real_timer>, handling=0)
            at pop/extern/lib/pop_timer.c:491
    #2  pop_timer (flags=0, ...) at pop/extern/lib/pop_timer.c:615

Three things in there kill the diagnosis everyone (including the author of
this file) started with:

  * **No children, at any depth.**  This is not a process waiting for a
    child.  Every earlier theory -- lost SIGCHLD, `sys_wait` parked on a
    reaped pid, a leaked pipe write end keeping `read_all` from seeing EOF
    -- requires a child to exist.  There is none.
  * **State R, `wchan` 0, syscall `running`.**  It is burning CPU, not
    parked.  "Hang" was the wrong word throughout; this is a spin.
  * **It is nowhere near the fork/wait code.**  The stack is the real
    interval timer.

So this is NOT the bug fixed in #47 (`shell-fork-hang-lost-sigchld.md`).
That one was a genuine park in `pause()` with a dead child; #47's bound
uses `poll()`, not `setitimer`, and does not appear on this stack.  The
two bugs share only a symptom and the suites they show up in.

## Mechanism

The wedge point is `syssleep`.  In `test_sysexecute_or_exit.p:61`,
`no_runaway` calls `syssleep(50)` -- half a second, to give a runaway
forked copy time to reach its marker file -- and that is exactly where the
transcript stops.

`next_timer` computes the time until the head of the timer queue expires
and, when it has already expired, splits on whether it is being called
from the signal handler (`pop_timer.c:451-489`):

    if (sec < 0 || (sec == 0 && usec <= half_clockint)) {
        /* expired */
        if (handling) {
            ... run or requeue the entry ...
        } else {
            /* not handling immediately -- generate trap */
            sec = usec = 0;     /* to cancel itimer */
            TIMER_RAISE_TRAP(timerp->T_SIG, timer_handler);
        }
    }
    ...
    TIMER_SET_ITIMER(VIRT(timerp), sec, usec, timerp->T_SIG, timer_handler);

The captured frame #1 has `handling=0`, so this is the `else` branch: it
**cancels** the itimer (`setitimer` with 0/0 disarms, it does not fire
immediately) and relies on a Pop-11 trap to run the handler at the next
check point instead.

If that trap is not serviced, nothing can ever wake the sleep: no itimer
is armed, so no SIGALRM will arrive, and `SigPnd` confirms none is
pending.  The caller re-arms, `next_timer` finds the deadline still past,
cancels and re-traps, and the process spins -- which is precisely the
State R with a stack in `setitimer` that was captured.

Why a half-second sleep would be *already expired* when it is armed is the
part still to establish.  A loaded hosted runner is slow enough between
computing the deadline and arming the timer for the expired branch to be
reached, which fits a defect that appears on all three platforms in CI at
~30% and never on an idle developer machine.

## What was ruled out, and at what cost

Worth recording because most of it was wasted motion from reasoning ahead
of evidence:

  * the suites in isolation -- 240 runs (40 rounds x 2 suites x 3
    platforms), clean
  * the whole 16-suite sequence under a wrapper -- 42 warm runs, clean
  * cold start, i.e. a freshly booted runner's first run -- 15 samples,
    clean (under 2% likely if cold start drove a 30% rate)
  * a time-correlated runner incident -- the first four hangs fell inside
    one 17-minute window, which looked compelling until the same config
    hung again 6.5 hours later
  * a slow suite rather than a wedge -- `TEST_TIMEOUT=600` settled it

The 240 and 42 figures are worth less than they look: both were collected
through `tools/debug/forkwait-probe.sh`, which *wrapped* the invocation
(foreground to background, piped stdout to a file, `TEST_TIMEOUT` raised)
and changed three variables at once.  The spin does not happen under that
wrapper -- 57 wrapped sequences clean against 6 hangs in 21 plain legs --
so those runs measured the instrument, not the bug.  Which of the three
variables suppresses it is unknown and is a live clue, since whatever it
is presumably perturbs the timing that makes the deadline land in the
past.

`tools/debug/hang-watch.sh` exists because of that mistake: it observes a
byte-for-byte unmodified invocation from a separate process and signals
nothing, leaving the killing to `test-libs.sh`'s own watchdog.

## Next

1. A second and third captured stack, to confirm the spin is really in
   this loop and not a coincidental sample.  (Two more runs were in
   flight when this was written.)
2. Instrument `syssleep`'s deadline arithmetic -- log the requested
   interval, the clock at arming, and the computed remainder -- to show
   the expired branch being taken.
3. Then the fix.  The `else` branch cancelling the itimer and trusting a
   trap is the suspect design: an expired real timer wants its handler run
   or its itimer armed with a minimum non-zero value, not disarmed.
