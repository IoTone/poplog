# syssleep spins at 100% CPU on an already-expired real timer

**Status:** spin confirmed by two independent stacks; the loop is identified,
the reason the deadline is in the past is not.  Fix not written.
**Platforms:** all three hosted CI platforms (x86_64 Linux, aarch64 Linux,
macOS arm64).  Never reproduced on a developer machine.
**Rate:** 7 hangs in 27 release-gate legs, about 26% per leg.
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

A second run caught the same suite on the same platform at the same age
(pid 4055, 151s, run 39025084678), and it is the sample that turns one
stack into a mechanism:

    State:  R (running)        wchan: 0        syscall: running
    SigPnd: 0000000000000000
    SigBlk: 0000000000000000       <- NOT blocked this time
    #2  pop_timer (flags=0, ident=6138144, handler=0x0, tvp=0x0)
            at pop/extern/lib/pop_timer.c:532

Same process state, no children, different instruction: the first sample
was inside `next_timer` with SIGALRM blocked, this one is entering
`pop_timer` with the mask already restored.  Two samples at two points of
the same BLOCK_SIG/RESTORE_SIG window is a loop being cycled, not one
instruction stuck.

The arguments pin down the caller: `handler=0`, `tvp=0`, `ident` nonzero
is the GET/CANCEL path, which is `Get_tim(astp, _0, _NULL)` at
`pop/src/sys_timer.p:182` -- "cancel any existing timer for astp", the
first thing the `sys_timer` updater does.  So the Pop-11 side is calling
`sys_timer` over and over, each call re-entering the queue code.

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

The sharper point, from reading the rest of `next_timer`: **the
`handling=0` branch never dequeues the entry.**  Only `handling=TRUE`
-- reached from `timer_handler`, i.e. from an actual delivered signal --
takes the entry off `T_QUEUE` and frees or requeues it.  So an expired
head of queue that is not serviced is *permanent*: it stays at the head,
and every later call that touches the queue finds it expired again,
disarms the itimer again, and raises the trap again.  The loop is
self-sustaining and needs no further bad luck to keep going, which is why
raising `TEST_TIMEOUT` to 600s changes nothing.

`TIMER_RAISE_TRAP` on Unix is `kill(getpid(), SIGALRM)`
(`pop_timer.c:161`), issued while `BLOCK_SIG` holds SIGALRM blocked, so it
lands pending and fires at `RESTORE_SIG`.  Whether that delivery actually
reaches `timer_handler` in this state is the next thing to establish;
the `SigPnd: 0` in both samples says that at neither instant was one
waiting.

Why the deadline is in the past at all is still open, and the earlier
guess here -- a loaded runner being slow between computing the deadline
and arming the timer -- is weak: `ADDTIM` and the expiry comparison are
microseconds apart in the same call path, and half a second is a long
time to lose between them.  Two better candidates:

  * **A zero absolute deadline.**  `next_timer` skips the clock
    subtraction when `E_SEC|E_USEC` is 0, leaving `sec = usec = 0`, which
    always compares as expired.  The setting path creates exactly that
    for a zero interval ("elseif zero interval, leave as zero and expires
    immediately", `pop_timer.c:562`), and `sys_timer.p`'s
    `returnunless(usec)` does not catch integer 0, since 0 is true in
    Pop-11.  `syssleep(50)` passes 500000, so this is not our caller --
    but it is a live way to wedge the queue from Pop-11.
  * **A forward step of the wall clock.**  `TIMER_GET_CLOCK` for a real
    timer is `gettimeofday`, i.e. CLOCK_REALTIME.  An NTP step forward
    between arming and the first check puts the deadline in the past once
    -- and because of the no-dequeue property above, once is enough to
    wedge for good.  Hosted runners discipline their clocks; an idle
    laptop in a two-minute test does not.  This fits "CI only" better
    than anything else so far, and it is testable.

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

1. ~~A second captured stack.~~  Done; see above.  It is a loop.
2. Instrument the expired branch, not `syssleep`: on the Nth consecutive
   `handling=0` expiry, print the head entry's absolute `E_SEC/E_USEC`,
   the clock just read, and the computed remainder, once, to stderr
   behind an environment variable so ordinary builds are untouched.  That
   separates the two candidates above -- a 0/0 entry prints zeros, a
   clock step prints a deadline a plausible distance in the past -- and
   it is a dozen lines in `pop_timer.c`.
3. The fix does not depend on which one it is, and is worth making
   either way: `next_timer` must never leave an expired entry queued with
   no timer armed.  Arming a minimum non-zero itimer instead of
   disarming makes the signal actually arrive, so the handler runs with
   `handling=TRUE`, the entry is dequeued, and the loop cannot form
   whatever put the deadline in the past.
4. Judge the fix by the gate, honestly: at a 26% per-leg rate, a run of
   clean x86_64 legs only means something past about ten of them
   (0.74^10 is under 5%).  Fewer than that is re-rolling until green,
   which is the thing this whole exercise was meant to stop.
