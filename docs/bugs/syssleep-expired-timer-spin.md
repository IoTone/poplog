# syssleep spins at 100% CPU on an already-expired real timer

**Status:** spin confirmed by four independent stacks.  **The timer
diagnosis below is refuted** -- an engine instrumented at the suspect
branch printed nothing, and the spin survives the fix.  Current reading:
a busy loop in `read_pipe`/`popen_drain` over a pipe at EOF, with
`pop_timer` merely where a loop that arms a timeout every iteration spends
its cycles.  See "The timer was a red herring".

The filename is now wrong and is being kept until the real mechanism is
nailed down, so that links to it keep working.
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
    Pop-11.  `syssleep(50)` passes 500000, so this is not our caller.

    **Tested, and it does not wedge** -- which is the useful part.
    `syssleep(0)` locally takes this exact branch once and returns
    immediately, and with the instrument at `POP_TIMER_DEBUG=1` prints:

        pop_timer: 1 expiries on real queue, handling=0;
        deadline 0.000000 (zero, always expired) ident 4295168232
        repeat 0.000000 blocked 1 pending 0 armed 0.000000

    So the queue really can hold a permanently-expired entry, the itimer
    really is disarmed (`armed 0.000000`), and the raise-and-trap path
    still services it.  An expired deadline is therefore **not
    sufficient**: the spin additionally needs the raised SIGALRM to go
    unserviced.  That is why the instrument reports `blocked`, `pending`
    and the armed itimer as well as the arithmetic.
  * **A forward step of the wall clock.**  `TIMER_GET_CLOCK` for a real
    timer is `gettimeofday`, i.e. CLOCK_REALTIME.  An NTP step forward
    between arming and the first check puts the deadline in the past once
    -- and because of the no-dequeue property above, once is enough to
    wedge for good.  Hosted runners discipline their clocks; an idle
    laptop in a two-minute test does not.  This fits "CI only" better
    than anything else so far, and it is testable.

## The timer was a red herring

Four stacks now, all x86_64 Linux, all `test_sysexecute_or_exit`, all
`State: R` with no children, and all with the program counter in
`pop_timer`.  That is what made the timer-queue story look strong.  Three
pieces of evidence taken together kill it:

  * **The instrumented engine printed nothing.**  `POP_TIMER_DEBUG=1000`
    reports once the `handling=0` expired branch has been taken a thousand
    times; a spin through that branch passes a thousand in microseconds.
    Run 39065636219 hung for the full 600s and the log contains no
    `pop_timer:` line at all.  The expired branch is not being taken.  The
    instrument earning its keep by refuting the hypothesis it was built
    for is the whole reason it was built.
  * **The fix does not fix it.**  `timer-expired-rearm`, which arms a
    minimum itimer instead of cancelling, hung in exactly the same place
    (run 39065872100, pid 3886).
  * **The frames are the SETTING path, not a stuck queue.**  Two of the
    four dumps show `pop_timer(flags=0, ident=..., handler=_pop_timer_trap,
    tvp=0x7fffffff4650)` -- a *fresh* timeout being armed -- and one shows
    the GET/CANCEL path with `handler=0, tvp=0`.  Arm, cancel, arm, cancel
    is a loop calling something with a timeout on every iteration, which
    is where the cycles of any such spin would land.

So `pop_timer` is the scenery, not the bug.

## Where it actually wedges

Not `syssleep(50)` at `test_sysexecute_or_exit.p:61`.  The captured suite
output goes much further than that -- `sysexecute_or_exit`,
`run_unix_program`, `pipein` and `pipeout` all report PASS -- and stops in
the `sys_popen` case at line 98:

    no_runaway('sys_popen',
        procedure; popen_drain(sys_popen(noexec, [])) -> output endprocedure);

`popen_drain` (line 39) is the ordinary `read_pipe` idiom:

    repeat
        read_pipe(dev, buf, 4096, ref) -> n;
        quitunless(n);
        if n > 0 then s <> substring(1, n, buf) -> s endif
    endrepeat;

and `read_pipe` (`pop/lib/auto/sys_popen.p:94`) waits half a second for
input, reads if the device is ready, and otherwise returns `false` if
`cont(ref)` shows the child finished or `0` if it has not:

    sys_device_wait(dev, [], [], 5e5) -> (n, , );
    if n then sysread(dev, string, len) -> num;
    else      if cont(ref) then false -> num else 0 -> num endif
    endif

Two properties of that combination produce exactly the observed spin.  `0`
is true in Pop-11, so `quitunless(n)` does not stop on `0` -- by design,
since `0` means "alive, nothing yet".  And a pipe at EOF is *ready* for
`select`, so `sys_device_wait` returns ready, `sysread` returns 0
characters, and the loop goes round again immediately.  The `false` that
ends the loop can only be reached down the not-ready branch, which needs
`cont(ref)` -- the child's exit status, delivered by the
`report_finished` AST that `sys_fork` was given.  While that AST is
outstanding the loop spins at 100% CPU, arming and cancelling a 0.5s
timeout every iteration.

Usually the AST arrives within microseconds and nobody notices.  The
hypothesis for the ~26%: on a loaded hosted runner it sometimes does not
arrive at all, and then the loop never ends.  That makes this the same
family as #47 -- a lost child-status notification -- which is why it
surfaces in these suites, and it means my original child-wait instinct was
closer than the timer story that replaced it.  It is still a hypothesis:
the next instrument has to show whether `cont(ref)` is ever set.

## Two symptoms, one missing notification

Run 39065661703 hung two legs at once and they look nothing alike, which
is the most useful thing to happen to this investigation.

x86_64, `test_sysexecute_or_exit`: `State: R`, 100% CPU, the busy loop
above.

macOS arm64, `test_http_server` (pid 6816, 154s):

    6816  6813 S<   .../basepop11 .../tools/tests/test_http_server.p
    --- children and grandchildren ---
    (none)
    frame #0: libsystem_kernel.dylib`poll + 8
    frame #1: basepop11`pause_popintr at c_core.c:1381:5

`S<`, not `R` -- parked, not spinning -- in `syshibernate`'s `poll`,
which is the 100ms-bounded park #47 introduced.  So it wakes every 100ms,
finds nothing to service, and parks again, forever.

Different constructs, identical situation: **something the process is
waiting to be told never gets told to it**, and no children exist to tell
it.  One waiting construct busy-polls a pipe that is permanently ready
(x86_64), the other parks and re-parks (macOS).  That unifies the three
platforms, explains why the suite differs by platform, and puts the root
cause back in the child-status notification path -- #47's family, which
fixed one lost-SIGCHLD instance in `c_core.c` and evidently not all of
them.

Also worth noting against the timer story: this leg printed no
`pop_timer:` line either, so the negative evidence now covers macOS as
well.

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

0. A syscall histogram, now in `hang-watch.sh`: two seconds of
   `strace -c` on the wedged pid.  `select` + `read` in the hundreds of
   thousands confirms the pipe-at-EOF loop; `setitimer` and `sigprocmask`
   alone would send this back to the timer.  Dispatched on
   `gate-timeout-bisect`.
1. ~~A second captured stack.~~  Done; see above.  It is a loop.
2. ~~Instrument the expired branch~~ -- done, and it refuted the
   hypothesis: on the Nth consecutive
   `handling=0` expiry, print the head entry's absolute `E_SEC/E_USEC`,
   the clock just read, and the computed remainder, once, to stderr
   behind an environment variable so ordinary builds are untouched.  That
   separates the two candidates above -- a 0/0 entry prints zeros, a
   clock step prints a deadline a plausible distance in the past -- and
   it is a dozen lines in `pop_timer.c`.
3. ~~The fix.~~  Written and **not the fix for this bug** -- the gate hung
   with it in place (run 39065872100).  Keep or drop it on its own
   merits as hardening, not as a bug fix; on branch
   `timer-expired-rearm`: `next_timer`
   arms one clock interval instead of cancelling, so the signal arrives
   even when the trap is not serviced, the handler runs with
   `handling=TRUE`, and the entry is dequeued.  The queue stops being
   wedgeable whatever put the deadline in the past.  Deliberately a
   separate branch from the instrument, so each is judged on its own.
   Locally 16/16 suites green and `10 x syssleep(50)` still 5.05s.
4. Judge the fix by the gate, honestly: at a 26% per-leg rate, a run of
   clean x86_64 legs only means something past about ten of them
   (0.74^10 is under 5%).  Fewer than that is re-rolling until green,
   which is the thing this whole exercise was meant to stop.
