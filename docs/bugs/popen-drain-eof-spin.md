# read_pipe spins at 100% CPU on a pipe at end of file

Found 2026-10-17 by `.github/workflows/skill-release.yml` running all 16
library suites on hosted runners for the first time; **fixed** the same
day in `pop/lib/auto/sys_popen.p` (branch `popen-eof`).  This is the
intermittent CI hang that wedged about a quarter of the release gate's
test legs, and 7-8 of 8 back-to-back sampling rounds on x86_64.

It was the fourth hypothesis.  The investigation history -- three
mechanisms that each fit every symptom and were each killed by a
measurement, plus the instruments that did the killing -- is in
[`sigchld-coalesce-lost-child-status.md`](sigchld-coalesce-lost-child-status.md).
One of the three, coalesced SIGCHLD dropping child-status asts, was a
real bug and is fixed separately (#57); it just was not this.

## Symptom

A library suite stops making progress after its visible checks have
passed -- `test_sysexecute_or_exit` on x86_64 Linux, in its `sys_popen`
case -- and `tools/test-libs.sh` reports a timeout.  The process has no
children, `State: R`, and burns a full core.

## What it is

`read_pipe` (`pop/lib/auto/sys_popen.p`):

    sys_device_wait(dev, [], [], 5e5) -> (n, , );
    if n then
        sysread(dev, string, len) -> num;
    else
        if cont(ref) then false -> num else 0 -> num endif
    endif

A pipe at end of file is **ready** for `select`, for ever.  So once the
pipe hits EOF the ready branch is taken every time, `sysread` returns 0
characters, and `read_pipe` returned `0` -- its code for "alive, nothing
yet".  The `else` branch is the only place `cont(ref)` is consulted and
the only one that can return `false`, and it has become unreachable: no
notification of any kind can end the loop.  The documented drain

    repeat
        read_pipe(dev, buf, len, ref) -> n;
        quitunless(n);
        ...
    endrepeat

then spins for ever, `0` being true in Pop-11.

The proof is a 2-second `strace -c` of a wedged runner (captured by
`tools/debug/hang-watch.sh`, kept in
[`evidence/`](evidence/)):

    49.12%   24503  rt_sigprocmask
    25.13%   12252  setitimer
    13.11%    6126  pselect6     <- 0 errors: READY every time
    12.64%    6125  read         <- 0 errors: 0 bytes, EOF

~3000 select+read pairs a second.  The `setitimer` pair and four mask
saves per iteration are `sys_device_wait` arming and cancelling its 0.5s
timeout -- which is why every captured stack had its program counter in
`pop_timer` and sent the investigation chasing the timer, and then
child-status delivery.  The timer was the loop's cost, never its cause.

## Why only sometimes

`sys_popen` forked without closing its copy of the child's write end in
the parent.  While that copy is open the pipe cannot reach EOF, so the
drain ends by the `else` branch and `cont(ref)` -- the normal, working
path, at the price of one 0.5s timeout per call after the output is
exhausted and a leaked file descriptor per `sys_popen`.  The pipe only
hits EOF when something closes the orphaned device -- a garbage
collection, at a time of its choosing.  Hence the platform split
(x86_64 8 of 8 sampling rounds, aarch64 0 of 8) and the resistance to
every notification-side fix.

## Reproducing

Deterministic, local, no CI:

    syspipe("line") -> (w, r);
    sysclose(w);                        ;;; no writer: r is at EOF
    read_pipe(r, buf, 4096, consref(false)) =>   ;;; was 0, for ever

Both states of the ref gave `0 0 0 0 0` before the fix.

## The fix

Two halves, both in `pop/lib/auto/sys_popen.p`:

  * `read_pipe`: a ready device whose read returns 0 characters is at end
    of file -- report `false` (finished), not `0`.
  * `sys_popen`: close the parent's copy of the child's write end, as
    `pipein` and `pipeout` already do.  EOF then arrives exactly when the
    child is done with the pipe, the drain ends promptly without waiting
    on `cont(ref)`, and the descriptor is no longer leaked.

Either half alone changes behaviour for the worse in some corner: the
close without the EOF handling makes the spin deterministic instead of
intermittent; the EOF handling without the close leaves the drain ending
at a GC's whim or a status poll's pace.  Together the drain ends when the
pipe does.
