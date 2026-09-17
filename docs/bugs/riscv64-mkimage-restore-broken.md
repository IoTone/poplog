# riscv64: mkimage-built .psv images no longer restore (machine1)

Found 2026-09-16 while verifying the `_posword_mul_high` fix
(`random-int-64bit.md`) on `machine1` (StarFive VisionFive, Ubuntu 24.04,
riscv64).  **Not fixed. Not diagnosed.**  `validate-riscv64.sh` is 1/14.

**I caused the loss, not the bug:** rebuilding the tree destroyed a working
`basepop11` from 2026-09-10 (the link rule deletes it before relinking) and
no rebuild since produces a working one.  There is no backup.

## Symptom

The engine itself is fine.  It compiles and runs `.p` files correctly —
including the `random` fix, which was verified there
(`random0(1000)` -> `{773 245 56 841 243 904}`).  Gate 8 of
`validate-riscv64.sh` (FFI float ABI, the one gate that restores no image)
passes.

Every `mkimage`-built image crashes on restore:

```
$ setarch -R ./poplog basepop11 -target/psv/startup.psv <<< '2+2 =>'

<<<<<<< Access Violation: PC = FFFFFFA3FF848492, Addr = FFFFFFA3FF848492,
        Code = 1 >>>>>>>
;;; MISHAP - serr: MEMORY ACCESS VIOLATION (see above)
```

`PC == Addr` — a jump to a wild address, not a data fault.

## What has been ruled out

| hypothesis | test | result |
| --- | --- | --- |
| The `_posword_mul_high` fix | reverted to the original `aarith.s`, full clean rebuild | **identical 13 failures** — not the cause |
| An interrupted/half-built tree | `rm` all stamps + `target/obj/*.{olb,wlb}` + `poplink_*.o`, full rebuild | still 13 failures |
| A stale `corepop` seed | `sha256sum` vs `nix/seeds/corepop-riscv64-linux` | **byte-identical** — re-bootstrapping from the published seed cannot change anything |
| Drifted sources | per-file sha256 of all 432 `pop/src/*.{p,ph,s}` vs the repo | identical (only `arm64/aarith.s`, irrelevant to a riscv64 build) |
| ASLR / missing `setarch` | stack address across runs: varies bare, **fixed** (`3ffffdf000`) under `setarch -R` | setarch works correctly; images fail with AND without it |
| `-nonwriteable` image flag | rebuilt `startup.psv` without it | still crashes |
| `syssave`/restore broken generally | saved a small heap, restored it | **works** — restores cleanly and the variable survives |
| The documented rebuild path | `validate-riscv64.sh --rebuild` | still 1/14 |

So: save/restore works for a small image; the 1.4 MB `mkimage` startup image
does not.

## The one thing that did change

`machine1` took an unattended upgrade on **2026-09-12**, two days after the
last good build:

```
Start-Date: 2026-09-12  06:29:48
Upgrade: libc6:riscv64 (2.39-0ubuntu8.8, 2.39-0ubuntu8.9),
         libc-bin, libc-dev-bin, libc6-dev, libc6-dbg, libc-devtools, locales
```

`cc` is unchanged (Ubuntu 13.3.0), `as` unchanged (binutils 2.42), kernel
unchanged (6.5.0-1016-starfive).  A glibc point release is the whole delta.

That is a plausible mechanism for a system that restores saved images at
**fixed virtual addresses** — a different libc changes where things land,
and with ASLR off the layout is deterministic but *different* from the one
the image was built against.  It is only a lead: it has not been tested,
and it does not by itself explain why a small `syssave` image restores fine
while the big one does not.

## The glibc lead is still UNTESTED

The safe way to test it — extract `libc6` 2.39-0ubuntu8.8 (still on
Launchpad; apt's cache is empty, unattended-upgrade cleans up) and run the
engine under the old dynamic loader without touching the system — **does
not work as a test**:

```sh
setarch -R ./poplog /tmp/g88/.../ld-linux-riscv64-lp64d.so.1 \
    --library-path /tmp/g88/.../riscv64-linux-gnu:/lib/riscv64-linux-gnu \
    target/pop/basepop11 -target/psv/startup.psv
# -> SIGSEGV, exit 139, no output at all
```

The control settles it: invoking the **system** loader the same way
segfaults identically.  Running a binary through an explicit `ld.so`
changes the process layout, which is precisely the variable under test, so
the method is confounded and says nothing about glibc either way.

Actually downgrading `libc6` on the box would be a real test, but it is a
remote machine reachable only by ssh: if libc6 breaks mid-install, ssh goes
with it and recovery needs physical access.  Not attempted.

## An observation worth chasing

`syssave` of a small heap restores fine; the 1.4 MB `mkimage` startup image
does not.  That points at an address-space collision rather than at the
save/restore machinery — the small image fits wherever it lands, the big one
does not.

Under `setarch -R`, libc and the loader sit at `3ff7e46000-3ff7ffe000` and
the heap at `2aaaab5000`.  The startup image's header carries
`0x00000000009d4010` in its second word.  The faulting PC,
`FFFFFFA3FF848492`, has the shape of a sign-extended 32-bit value — the
same *class* of defect as the `random` bug in `random-int-64bit.md`, which
is suggestive and no more than that.

## Where to start

1. Compare the process map of a bare `basepop11` under `setarch -R` against
   what `startup.psv` expects — `PC = FFFFFFA3FF848492` should be traceable
   to a specific relocation.
2. Bisect by image size / content: `syssave` of a small heap works, the
   1.4 MB startup image does not.  Find the threshold or the construct.
3. If the glibc lead holds, `libc6` 2.39-0ubuntu8.8 is still in the apt
   cache and can be pinned to confirm by reverting it.
4. `x86_64` and `aarch64` are unaffected; `raspi5` rebuilt from the same
   commit and its only failures are the separate, documented stat bug.

## Step 0 — done (2026-09-17)

The broken state and the working x86-64 reference are archived off-box in
the public, versioned bucket `poplog-builds`, each with a `.sha256` and a
`manifest.json` (kernel, glibc, compiler, validation score, source
provenance):

    https://poplog-builds.s3.us-west-1.amazonaws.com/builds/riscv64-linux/machine1-riscv64-broken-2026-09-16.tgz
    https://poplog-builds.s3.us-west-1.amazonaws.com/builds/x86_64-linux/red5buntu-x86_64-good-2026-09-17.tgz

`tools/snapshot-build.sh <platform> good` does this for any tree in one
step.  raspi5 was unreachable and is not yet archived.
