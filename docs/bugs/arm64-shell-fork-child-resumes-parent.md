# A forked child intermittently resumes the parent's code on arm64 Linux

Found 2026-10-14 while clearing the last of the arm64 CI suite failures on
`dietpi5-kordshom` (Pi 5, DietPi, kernel 6.18.33, 16K pages).  **Not
fixed.**  Pre-existing and not CI-blocking -- see "Why CI is unaffected".

## Symptom

A loop of `shell_run` calls wedges.  60 of them, output to a file:

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
| Pi 5, DietPi aarch64 (output to a pipe) | 2 | 1 |
| macOS arm64 (same tree, same library) | 3 | 0 |
| riscv64 Linux (`machine1`, same tree) | 3 | 0 |

A 60-call loop survives about one run in five, so a single `shell_run` has
roughly a 2-3% chance of wedging.  That makes `tools/tests/test_shell.p`
-- eight forks -- hang perhaps one run in five as well.  It hung 3 of 3 runs when its
output went to a pipe and passed 3 of 3 to a file, and that split does not
survive the loop test above, which hangs either way.  **Treat the
pipe/file distinction as noise; it is a probability, not a condition.**

A `basepop11` stuck on `test_shell.p` had been sitting in `~/poplog` on
that board for 28 days when this was found, so it long predates the CI
work.

## Evidence

Taken live, 25 seconds into a hung run.  Four `basepop11` processes where
there should be one:

| pid | wchan | blocked in | fd 0 | fd 1, 2 | other fds |
| --- | --- | --- | --- | --- | --- |
| 372135 | `anon_pipe_read` | `read(3)` | pipe | the outer pipe | |
| 372136 | `do_wait` | `wait4` | /dev/null | the outer pipe | |
| 372138 | `do_wait` | `wait4` | /dev/null | the outer pipe | |
| 372139 | `anon_pipe_read` | `read(4)` | /dev/null | **a capture pipe** | fd 3 = `test_shell.p`, fd 4 = another pipe |

Read 372139, which is the interesting one:

  * **fd 1 and 2 point at a capture pipe**, not at the process's own
    stdout.  Only one place does that: the child branch of `spawn` in
    `pop/lib/lib/shell.p`, which assigns `wr -> popdevout` (and
    `popdeverr` when `errdest` is `"merge"`).  So this process entered the
    child branch.
  * **fd 3 is the test suite's source file**, so it is running the suite.
  * It is **blocked reading fd 4, a different pipe** -- which is what
    `collect` does: `read_all(dev)` on the pipe's read end.

A process cannot be in the child branch and also in `collect`.  The child
neither exec'd nor exited: it fell back into the *parent's* continuation
and is now waiting to read output from a command that was never started.
Nothing will ever write to that pipe, so the read never returns, and the
two processes in `do_wait` are waiting on children that will never exit.

That is the exact failure mode `pop/lib/auto/sysexecute_or_exit.p` was
written against -- "a handler in the copied call stack resumes the
PARENT'S code in the child" -- except that `shell.p` *does* call
`sysexecute_or_exit`, and it still happens.

## Ruled out

  * **`sys_fork` + `sysexecute` themselves.**  400 cycles of bare
    `sys_fork(true)` / `sysexecute('/bin/true', ...)` / `sys_wait`, each
    process leaving a mark in a file: 400 children entered the child
    branch, 400 were reaped, `sysexecute` returned 0 times, no hang.  The
    primitive pair is reliable; it is the pipe path that breaks.
  * **The arm64 `sys_file_stat` layout bug** (`aarch64-stat-layout.md`).
    The hang persists on an engine with that fixed.
  * **Unflushed buffered stdout at fork time.**  One `shell_run` with 200
    buffered bytes pending completes normally.
  * **Being an arm64 bug as such, and being a Linux bug as such.**  macOS
    arm64 runs the same library over 180 forks without a miss, and so does
    riscv64 Linux -- which shares this tree's generic Linux fork/exec path
    *and* its `ARM64_LINUX` headers.  Only the two together fail, which
    leaves the aarch64-Linux-specific parts: `pop/src/arm64/*.s`, the
    signal and timer handling `sys_fork`/`sysexecute` touch on that
    platform, and the board's **16K page size** (the one configuration
    detail no other platform here shares -- and the arm64 code generator
    has had a page-boundary bug before, see
    `aarch64-large-literal-sigill.md`).

## Why CI is unaffected

  * The pre-packaging gate runs `test_primitives` and `test_fileutils`,
    neither of which forks.
  * `tools/test-libs.sh` runs every suite under a watchdog and kills the
    process **group**, so a hung suite is a `FAIL (timed out after Ns)`
    and not a stuck stage -- which is why this was invisible: the full-run
    numbers quoted for the board were collected with per-suite redirection,
    where `test_shell` happened to pass.
  * Nothing in the shipped skill's smoke tests uses LIB * SHELL.

The cost is real but bounded: a user whose program calls `shell_run` in a
loop on a Pi has a few-percent chance per call of a process that never
returns.

## Where to look next

  1. **Get the errno.**  If `execve` is failing, the message goes to the
     child's `popdeverr` -- which is the capture pipe -- so it lands in
     output the parent is blocked trying to read, i.e. nowhere.  Instrument
     `sysexecute_or_exit`'s `prmishap` to append to a FILE as well, rerun
     the loop, and the question is answered in one go.  `strace` is not
     installed on that board (`gdb` is).
  2. **Rule the fork result in or out.**  Have `spawn`'s two branches each
     append the pid, the `sys_fork` result and `popdevout`'s descriptor to
     a file, then compare what the hung process recorded against what it
     is doing.  If a process recorded the *child* branch and is in
     `collect`, the resumption is through the mishap/exit machinery; if the
     branches disagree with the pids, `pop_fork`'s result is being read
     wrongly in the child.
  3. **Check the handler stack.**  `shell.p`'s callers include
     `check_mishaps` from LIB * POPTEST in the same suite, and a `dlocal`
     exit action in a copied stack is exactly what resumes parent code.
     Try the loop with no poptest in the image.
  4. `gdb` on a stuck child for the C-level frames -- it will at least
     confirm `read` on the capture pipe and no `execve` on the way in.

## Reproduce

```sh
# on an aarch64 Linux board, in a built tree
cat > /tmp/fork_loop.p <<'EOF'
uses shell;
vars out, status, i;
for i from 1 to 60 do
    shell_run('echo hi') -> (out, status);
    printf('%p ok %p\n', [^i ^status]);
endfor;
printf('ALL DONE\n');
EOF
for t in 1 2 3; do
    timeout -s KILL 60 ./poplog basepop11 /tmp/fork_loop.p > /tmp/q_$t.out 2>&1
    echo "trial$t rc=$? reached=[$(tail -1 /tmp/q_$t.out)]"
    pkill -9 basepop11
done
# while one is hung, in another shell:
for p in $(pgrep -f basepop11); do
    echo "== $p wchan=$(cat /proc/$p/wchan) syscall=$(cut -d' ' -f1-2 /proc/$p/syscall)"
    ls -l /proc/$p/fd
done
```
