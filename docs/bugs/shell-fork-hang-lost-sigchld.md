# A lost SIGCHLD parks sys_wait in pause() forever

Found 2026-10-14 on `dietpi5-kordshom` (Pi 5, DietPi, kernel 6.18.33, 16K
pages) while clearing the last arm64 CI suite failures; diagnosed and
**fixed 2026-10-15** in `pop/extern/lib/c_core.c`.  Pre-existing: a
`basepop11` stuck on `test_shell.p` had been sitting on that board for 28
days when this was found.

Filed originally as `arm64-shell-fork-child-resumes-parent.md`, after a
first diagnosis that turned out to be wrong in an instructive way -- see
"What the first diagnosis got wrong".

## Symptom

A loop of `shell_run` calls wedges, with no error and no CPU use:

```
uses shell;
vars out, status, i;
for i from 1 to 60 do
    shell_run('echo hi') -> (out, status);
    printf('%p ok %p\n', [^i ^status]);
endfor;
printf('ALL DONE\n');
```

| platform | trials | hung |
| --- | --- | --- |
| Pi 5, DietPi aarch64, 16K pages | 5 | **4** |
| macOS arm64 (same tree, same library) | 3 | 0 |
| riscv64 Linux (`machine1`, same tree) | 3 | 0 |

About one 60-call run in five survived on the Pi, so roughly 2-3% of
`shell_run` calls hung -- enough to wedge `test_shell.p` (eight forks)
about one run in five as well.

## What it is

`sys_wait` waits like this (`pop/src/syswait.p:100-124`):

    repeat
        returnif(is_dead(find_proc(pid))) ();
        syshibernate()
    endrepeat

`syshibernate` is `pause_popintr`, which was a bare `pause()` on every
platform except Apple.  If `SIGCHLD` is delivered *after* `is_dead` says
"not yet" but *before* `pause()` parks, the wake-up has already been
spent: nothing further will arrive, and the parent sleeps forever next to
a child that is already dead and reaped.

Nothing about this is arm64-specific, Linux-specific, or fork-specific.
It is a plain check-then-park race in platform-neutral Pop-11.

## Evidence

Every fork branch, exec attempt and exit path was made to append to
`/tmp/forkdiag/p<pid>` -- one file per process, so parent and child
cannot lose each other's lines.  A hung run, verbatim:

    p379170 (parent)                    p379174 (child)
    --- loop 1                          CHILD branch: fork returned <false>
    spawn: pipe wr=... rd=...           CHILD: calling sysexecute_or_exit
    PARENT branch: fork returned 379174 sysexecute_or_exit: about to exec /bin/sh

The child's log ends at `about to exec` with no `prmishap`, no
`sysexecute RETURNED` and no `die()` -- so the exec **succeeded**.  Live
state 25 seconds in:

    $ ps -eo pid,ppid,stat,args | grep 379174
    379174  379170  Z  [sh] <defunct>        # exec'd, ran, exited, reaped

    $ ls -l /proc/379170/fd
    0 -> /dev/null   1 -> /tmp/diag4.out   2 -> /tmp/diag4.out   3 -> /tmp/diagdrv.p
                                           # no pipe: read_all already finished

    $ cat /proc/379170/syscall
    73 0x0 0x0 0x0 0x0 0x0 0x0 ...         # ppoll(NULL, 0, NULL) -- glibc pause()

    $ gdb -p 379170 -batch -ex bt
    #2  pause () from /lib/aarch64-linux-gnu/libc.so.6
    #3  pause_popintr () at pop/extern/lib/c_core.c:1375

So: pipe drained and closed, child a zombie, parent in `pause()`.  The
parent is past `read_all` and inside `sys_wait`.

## Why macOS never showed it

Because macOS was **already fixed**.  `c_core.c` carried this, under
`#if defined(__APPLE__)`:

    /* pause() has an unfixable race: if the wake-up signal's AST is
     * processed at a check point after the caller re-tested its wait
     * condition but before pause() parks, nothing is left to wake the
     * process (observed as sys_wait/syshibernate hanging in sigsuspend
     * with the child long dead).  Bound the park at 100ms with poll() */

Same race, same mechanism, written down after it was hit on Darwin, and
fenced to one platform.  The `#else` was bare `pause()`.

## The fix

Bound the park on **every** platform -- `poll(NULL, 0, 100)` in place of
`pause()`.  A signal still interrupts it immediately (EINTR); a lost
wake-up now costs one 100ms tick, after which `syshibernate`'s caller
re-checks its own condition and proceeds.  The cost is a 10Hz tick while
a process is hibernating, which Darwin has been paying since the macOS
fix landed.

## Validation

| test | before | after |
| --- | --- | --- |
| 60-call loop, Pi 5 | 1 of 5 survived | **12 of 12** (720 calls) |
| `test_shell`, Pi 5 | hung ~1 run in 5 | 6 of 6 PASS (21 checks) |
| 60-call loop, riscv64 | 0 of 3 hung already | 6 of 6 (360 calls) |
| `test_shell`, riscv64 | passed already | 3 of 3 PASS |
| full matrix, Pi 5 | -- | **16/16** |
| full matrix, macos-arm64 | -- | **16/16** |
| full matrix, linux-x86_64 | -- | **16/16** |
| engine gate, riscv64 | -- | green, clean rebuild from seed |

The change is unconditional, so it was rebuilt and re-run on all four
platforms, not just the two that hung.

At 2-3% per call, 720 consecutive calls surviving by luck has a
probability around 1e-8.

The bounded park is not in the common path: 60 `shell_run` calls on the
Pi take 169, 175 and 169 ms across three runs -- about 2.8 ms each.  If
every call were paying the 100 ms tick the loop would take over 6 s, so
`SIGCHLD` is interrupting `poll` immediately, as intended; the tick is
only what a *lost* wake-up now costs instead of hanging forever.

## Still true from the original investigation

  * **`sys_fork` + `sysexecute` are reliable.**  400 bare
    `sys_fork(true)` / `sysexecute('/bin/true')` / `sys_wait` cycles: 400
    children entered the child branch, 400 were reaped, no hang.  (The
    cycle was tight enough that the signal usually arrived while the
    parent was still in `is_dead`, which is why it never lost one.)
  * The arm64 `sys_file_stat` layout bug (`aarch64-stat-layout.md`) is
    unrelated -- the hang persisted on an engine with that fixed.
  * Unflushed buffered stdout at fork time is unrelated.

## What the first diagnosis got wrong

It read a hung process's `/proc` -- fd 1 and 2 on a capture pipe, fd 3
the suite source, blocked reading another pipe -- and concluded the child
had entered `spawn`'s child branch, failed to exec, and resumed the
*parent's* continuation through a handler in the copied call stack.  That
is a real failure mode (`sysexecute_or_exit.p` exists because of it), and
the fd pattern genuinely looked like it.

Two things made it wrong:

  1. **Inference from fd layout instead of from the process's own
     record.**  One file per process, written at each branch, settled in
     one run what the fd tables had suggested for a day.  The child said
     plainly that it had exec'd.
  2. **Reading a platform difference as a platform bug.**  macOS and
     riscv64 passing while aarch64 Linux failed pointed at
     "aarch64-Linux-specific code" and the board's 16K pages -- the one
     configuration detail no other platform shared.  The actual
     difference was `#if defined(__APPLE__)` around the fix, and riscv64
     was simply losing the race less often.  A platform that does not
     reproduce a race is evidence about timing, not about cause.

The lesson that generalises: when a bug's platform table has a hole,
check whether the lucky platform is lucky or **already patched** before
theorising about its hardware.

## Reproduce

```sh
# on a build WITHOUT the fix (pause() unbounded)
for t in 1 2 3 4 5; do
    timeout -s KILL 90 ./poplog basepop11 /tmp/fork_loop.p > /tmp/q_$t.out 2>&1
    echo "trial$t rc=$? reached=[$(tail -1 /tmp/q_$t.out)]"
    pkill -9 basepop11
done
# while one is hung:
p=$(pgrep -f 'basepop11 /tmp/fork_loop.p'); cat /proc/$p/syscall; gdb -q -p $p -batch -ex 'bt 5'
```
