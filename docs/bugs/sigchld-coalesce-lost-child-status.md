# One SIGCHLD, several dead children: the rest are never reaped

Found 2026-10-17 by `.github/workflows/skill-release.yml` running all 16
library suites on hosted runners for the first time.  The Jenkins gate ran
2 suites, so it could not have seen this.  **Fixed** the same day in
`pop/src/signals.p` with a regression test in
`tools/tests/test_sigchld_coalesce.p` (PR #57).

Sibling of [`shell-fork-hang-lost-sigchld.md`](shell-fork-hang-lost-sigchld.md)
(#47), which bounded the *park* this bug causes without curing the cause.
Two earlier diagnoses of this one were wrong; both are kept below, because
what refuted them is the useful part.

## Symptom

A library suite stops making progress after its visible checks have
passed, and `tools/test-libs.sh` reports:

    FAIL  test_sysexecute_or_exit  (timed out after 120s)

The suite differs by platform: `test_sysexecute_or_exit` on x86_64 Linux,
`test_http_server` on macOS arm64 and aarch64 Linux, `test_shell` (i.e.
`shell_run`) on x86_64 as well.  It is not a slow suite -- at
`TEST_TIMEOUT=600` the same suites wedge for the full ten minutes.

Rates, all on the same plain `sh tools/test-libs.sh`:

| configuration | legs/rounds | hung |
| --- | --- | --- |
| release gate, one sequence per leg | 39 | 10 (~26%) |
| `hang-sample`, 8 sequences back to back, x86_64 | 8 | **7** |
| `hang-sample`, 8 sequences back to back, macOS arm64 | 8 | 1 |
| `hang-sample`, 8 sequences back to back, aarch64 | 8 | 0 |
| local reproducer, 10 children dying together | 30 rounds | 17 rounds lost an ast, 25 in all |

Never reproduced on a developer machine *as a suite hang*; the underlying
loss reproduces on an idle laptop in under a second (see "Reproducing").

## What it is

`SIG_CHILD` does not queue.  One delivery can stand for any number of
child deaths -- the kernel keeps at most one pending.

`Get_os_process_trap` (`pop/src/os_process.p:39`) walks
`os_process_list`, `waitpid(WNOHANG)`s each entry, and on the **first**
one that has terminated records its status, sets `OSPROCF_DEAD`, builds
its ast closure and `return`s.  One child per call, by construction.

The dispatch in `Async_raise_signal` (`pop/src/signals.p:557`) called it
**once per signal**:

    if _data == _:SIG_CHILD then
        if testdef Get_os_process_trap
        and weakref Get_os_process_trap() ->> ast then
            Raise_astp(ast, false)

So when several children die close enough together to share a delivery,
one is reaped and the others are left on the list with `OSPROCF_DEAD`
clear -- and no further signal is coming for them.  Their asts never run.
Nothing else ever scans the list.

Both symptoms follow from that:

  * **`sys_wait` parks.**  Its loop (`pop/src/syswait.p:100-124`) tests
    `is_dead`, which only reads `OSPROCF_DEAD`, then calls
    `syshibernate()`.  The flag is never set, so it waits for good.  This
    is exactly #47's symptom, which is why #47's 100ms `poll()` bound
    helped and did not cure: the park is bounded, but nothing in the loop
    re-reaps, so the condition it re-checks never becomes true.
  * **`sys_popen`'s drain spins at 100% CPU.**  `read_pipe`
    (`pop/lib/auto/sys_popen.p:94`) returns `false` -- the only value that
    ends `popen_drain` -- only down its not-ready branch, and only when
    `cont(ref)` holds the child's status, which is written by the ast that
    never ran.  Otherwise it returns `0`, and `0` is true in Pop-11, so
    `quitunless(n)` keeps going.

## Reproducing

`tools/tests/test_sigchld_coalesce.p` forks ten children that each sleep
0.3s and exit, so they die together, each with an ast:

    ./poplog target/pop/basepop11 tools/tests/test_sigchld_coalesce.p

On an idle macOS arm64 laptop that loses asts in more than half of all
rounds on an unfixed engine, and the lost pids are always the *oldest* --
what a LIFO list scanned with `return`-after-first predicts.  Nothing in
this investigation had reproduced the bug off a hosted runner before.

## The fix

`pop/src/signals.p`: keep calling the trap until it reports that nothing
more has died.

    while weakref Get_os_process_trap() ->> ast do
        unless Raise_astp(ast, false) then Add(ast) endunless
    endwhile;

Measured with `tools/tests/test_sigchld_coalesce.p`, ten children dying
together:

| | rounds losing an ast | asts lost |
| --- | --- | --- |
| before | 17 of 30 | 25 |
| after | 0 of 30 | 0 |

The test fails 3 for 3 on an unfixed engine and passes 3 for 3 on a fixed
one, so ten rounds catch a regression with better than 99.9% probability,
and it is cheap enough to live in the suite set rather than in
`tools/debug`.

### A hole in the probe, not the engine

For an hour the fix looked partial: an earlier probe still lost about one
ast per 25 rounds with the drain in place, and this file said so.  That
probe accumulated reaped pids as

    [^^fired ^pid] -> fired

inside the ast.  Allocation is a check point and asts run at check
points, so an ast nested inside that cons loses the outer update: the
probe was dropping its own records.  The test above gives each ast a
preallocated slot -- no consing, no shared accumulator -- and reports zero
loss over 30 rounds.

What settled it was asking what kind of loss it was rather than
theorising: for a child whose ast never ran, `sys_wait` mishaps with
INVALID OR NONEXISTENT if the entry had been removed (reaped, ast lost)
and parks if the entry is still there (never reaped).  It mishapped --
the child *had* been reaped -- which pointed at the recording side, and
the recording side was mine.

## What the earlier diagnoses got wrong

Worth keeping, because the instruments that refuted them are reusable and
the reasoning errors were mine, not the evidence's.

**First: a child-wait bookkeeping bug** (lost SIGCHLD, `sys_wait` parked
on a reaped pid, a leaked pipe write end starving `read_all`).  Refuted
by the first captured dump: no children at any depth, `State: R`, `wchan`
0.  Correct in spirit, as it turns out, and discarded too readily.

**Second: a spin in the interval timer.**  Four captured stacks all had
their program counter in `pop_timer`, and `next_timer`'s already-expired
branch with `handling=0` really does cancel the itimer and trust a trap
(`pop_timer.c:481-491`).  Refuted three ways:

  * an engine instrumented at that branch (`POP_TIMER_DEBUG`, still in
    `pop_timer.c`) printed **nothing** through a 600s hang, on Linux and
    macOS both -- the branch is never taken;
  * a fix that arms a minimum itimer instead of cancelling hung
    identically, twice (written, measured, and thrown away);
  * two of the four dumps show the *arming* path with a live `tvp`, which
    is a loop calling something with a timeout every iteration -- the
    scenery of the real spin, not its cause.

`syssleep(0)` also takes that branch once and returns immediately, so a
permanently-expired entry is not sufficient to wedge anything.

**Measurement errors worth not repeating.**  240 isolated-suite runs and
42 whole-sequence runs were collected through `tools/debug/forkwait-probe.sh`,
which *wrapped* the invocation -- foreground to background, piped stdout
to a file, `TEST_TIMEOUT` raised -- and changed three variables at once.
The bug does not occur under that wrapper: 57 wrapped sequences clean
against 6 hangs in 21 plain legs.  Those runs measured the instrument.
`tools/debug/hang-watch.sh` exists because of it: it observes a
byte-for-byte unmodified invocation and signals nothing.  `hang-sample.yml`
keeps that discipline -- it repeats the plain command and only loops
around whole rounds.

A burst theory also died on contact: the first four hangs fell in one
17-minute window, which looked compelling until the same configuration
hung again 6.5 hours later.

And one instrument bug, since it cost a whole sampling run: `strace -c -p
PID -o /dev/stdout` **truncates** the dump file, because `-o` opens its
target with `O_TRUNC` and that target was the dump.  Seven hangs produced
one mangled entry and no histogram.  strace reports to stderr by default.
