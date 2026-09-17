# riscv64: large closures are emitted with a wrapped 12-bit offset (was: mkimage images no longer restore)

Found 2026-09-16 while verifying the `_posword_mul_high` fix
(`random-int-64bit.md`) on `machine1` (StarFive VisionFive, Ubuntu 24.04,
riscv64).  **Fixed 2026-09-17** in `pop/src/riscv64/closure_cons.p`; `validate-riscv64.sh`
14/14 on machine1 after a full-ladder rebuild.  See "Cause" and "Verified"
below.  Everything above the Cause section is the investigation as
it happened, including the leads that were wrong.

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
    https://poplog-builds.s3.us-west-1.amazonaws.com/builds/macos-arm64/MacBook-BR0-macos-arm64-good-2026-09-17.tgz

`tools/snapshot-build.sh <platform> good` does this for any tree in one
step.  raspi5 was unreachable and is not yet archived.

The **fixed** build (validate 14/14) is archived beside the broken one:

    https://poplog-builds.s3.us-west-1.amazonaws.com/builds/riscv64-linux/sf1-2-riscv64-linux-good-2026-09-17.tgz

(`sf1-2` is machine1's real hostname; the manifest carries the alias.)

## Cause (2026-09-17)

Not glibc, not ASLR, not the seed, not the sources, not the build ladder.
A riscv64 **codegen bug in the closure emitter**, `pop/src/riscv64/closure_cons.p`,
large-closure path (`nfroz > 16`):

```pop11
_clos@PD_CLOS_FROZVALS[_nfroz] _sub _clos -> _exec_offs;
_shift(_exec_offs, _20) _biset _16:00053F03 -> INSTR;    ;;; ld t5, exec_offs(a0)
```

The byte offset from the closure base to its data word grows with the
number of frozen values and is shifted straight into the `ld`'s **12-bit
signed immediate** with no range check.  Past `0x800` (about 250 frozvals)
bit 11 becomes the sign.  In `startup.psv` one closure had `_exec_offs =
0xa78`, encoded as `0xa7853f03` — the word in the image — and executed as
`ld t5, -0x588(a0)`.

The chain, every link read from the image file or the live process under
gdb (`break *0x18df38`, the `jalr` in `Sys$-Process_percent_args`):

1. The stub at `0x9d6aa8` computes its own record `0x9d6028` (matches `a0`
   at the fault), pushes it, then loads from `record - 0x588 = 0x9d5aa0`.
2. `0x9d5aa0` holds `0x00a4b023ff848493` — two instruction words of another
   procedure (`addi s1,s1,-8 / sd a0,0(s1)`).  Its low half, with bit 0
   cleared as `jr` does, **is the faulting PC** `...ff848492`.
3. The word it meant to load, `record + 0xa78 = 0x9d6aa0`, 8 bytes before
   the stub, holds `0x10b698` — a valid `basepop11` text address.

Decoding the record itself (layout from `syscomp/symdefs.p`; the record
pointer lands on `PD_EXECUTE`, so `PD_PROPS`/`KEY` are at -16/-8):

| field | value | meaning |
| --- | --- | --- |
| `PD_LENGTH` (+16, int) | 0x155 | 341 words = 2728 bytes |
| `PD_NARGS` (+21) | 0xff | unassigned, as closures are |
| **`PD_CLOS_NFROZ`** (+22, short) | **0x14b** | **331 frozen values** |
| `FROZVALS[331]` | 32 + 331 x 8 | **= 2680 = 0xa78**, the emitted offset |

2728 = 16 + 32 + 2648 + 8 (data word) + 24 (six instructions): the record is
consistent to the byte, and the bad immediate is exactly its frozval table
length.  The threshold is 32 + 8 x nfroz >= 0x800, i.e. **252 frozen values
or more**.

The image maps faithfully with no relocation on Linux (`file = mem -
0x9d3000`; the record's word 0 is at file `0x3028` and is identical in
memory), so the mis-emitted instruction is executed exactly as written.

Why the observations looked contradictory: a plain `syssave` image restores
fine because no large closure is on its startup path; `mkimage`'s image has
one.  arm64 is immune because its `ldr` immediate is unsigned and scaled by 8
(32 KB reach).  The bad value is not in the file because it is computed.  The
09-10 build worked because no closure in that image happened to cross the
threshold; something since pushed one over (the `locales` package in the
09-12 upgrade is a candidate, unproven) — but the bug is unconditional above
~250 frozvals regardless of what triggered it here.

## Fix

The data word is always 8 bytes before the code, so load it PC-relative —
an offset that cannot grow:

```
- ld    t5, exec_offs(a0)      ; base-relative; wraps at 0x800
+ auipc t5, 0                  ; 00000f17   (code+16)
+ ld    t5, -24(t5)            ; fe8f3f03   -> code-8, the data word
  jr    t5                     ; 000f0067
```

Stub grows from 6 to 7 instructions (32 -> 36 bytes) and the size
arithmetic follows.  Both encodings verified against `as -march=rv64gc` on
the target.  The small-closure path is unaffected: its offsets are bounded
by `nfroz <= 16`.

## Are there siblings?

Audited every riscv64 runtime emitter for the same shape — a computed byte
offset shifted into a 12-bit immediate without a range check:

| site | what it shifts | safe? |
| --- | --- | --- |
| `array_cons.p:80-84`, `pdr_compose.p:59-63` | `auipc`+`addi` pair (`_hi20`/`_lo12`) | yes — 32-bit reach, the right idiom |
| `pdr_compose.p:77-87` | `@@PD_EXECUTE`, `@@PD_COMPOSITE_P1/P2` | yes — fixed header offsets, a few words |
| `ass.p:254` I-type encoder | masks to 12 bits | yes — callers at 495 and 626 range-check and fall back to `hi20/lo12` |
| `closure_cons.p` small path | `_fv_offs`, `@@PD_CLOS_PDPART` | yes — bounded by `nfroz <= 16` |
| **`closure_cons.p` large path** | **`_exec_offs`, grows with `nfroz`** | **no — this bug** |

One site, now fixed.

## Verified (2026-09-17)

Full ladder under `setarch -R` on machine1 with the patched emitter
(`stamp_popc` rebuilt, tool checksums changed), then
`validate-riscv64.sh --rebuild`: **14 passed, 0 failed — PORT VALIDATED**,
22:19:45 UTC.  `random0(1000)`, `oneof` and `shuffle` are correct on the
rebuilt engine (the earlier fix, `random-int-64bit.md`, survives).

`tools/test-libs.sh` on the rebuilt engine, with the `poppcre`/`popcurl`
shims built: **12/14**.  The two that fail, `test_fileutils` (`file_size`)
and `test_zmachine` ("story file shorter than its header says"), are the
separate, documented stat bug (`aarch64-stat-layout.md` — size comes back as
the 4096 block size) and fail identically on raspi5.  Not related to this
bug, not touched here.

`tools/tests/test_primitives.p` now builds closures with 16, 17, 251, 252,
331 and 600 frozen values via `consclosure` and calls each — the 331 case is
this closure — so the emitter cannot regress silently again.  It passes on
riscv64, aarch64-darwin and x86_64.
