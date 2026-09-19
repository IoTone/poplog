# SIGILL compiling large literals on aarch64 Linux

**Status:** FIXED 2026-09-19 — root cause was a mitigation gated to Darwin only
**Severity:** high on the affected machine — the process dies, no mishap
**Found:** 2026-09-19, exporting classifier weights as Pop-11 source
**Affects:** aarch64 ELF (Linux) builds. macOS arm64 was never affected --
the mitigation was gated on, there. x86-64 never compiles this file.

## Symptom

Compiling a source file containing a large vector literal of floats kills
the process:

```
;;; LOADING /tmp/big1000.p

	<<<<<<< System Error: Signal = 4, PC = 0000000001015308 >>>>>>>

;;; MISHAP - serr: SYSTEM ERROR (see above)
```

Signal 4 is SIGILL: the engine executed an illegal instruction. This is a
crash in generated code, not a mishap.

Reproducer — a file of the form

```pop11
vars big = {-0.577447 -0.812281 ... };   ;;; N floats on one line
printf('ok %p\n', [% length(big) %]);
```

## What is measured, and what is not

Deterministic per file: the same file fails on every run, and passes on every
run on the other two platforms.

The failing set depends on N, but **not monotonically**:

| N floats | Pi |
|----------|-----|
| 500 | ok |
| 550 | SIGILL |
| 600, 750, 900, 1000, 1500, 2000, 2500 | SIGILL |
| 3000, 3500, 4096 | ok |

`big4096.p` contains the same first 600 numbers as the file that fails at
600, so the *content* is not the trigger. Setting `popdprecision` shifts the
band rather than removing it — with it true, N=1000 passes while N=2000 still
fails.

Two things remain unexplained, and are why this is filed open rather than
diagnosed:

1. Why the band has an upper edge at all.
2. Why `vision.p --check` loads a weights file containing a 4096-float
   literal on the Pi without incident, while a bare program loading the same
   file crashes — in *both* top-level and inside-a-procedure contexts.

Non-monotonic behaviour that moves when an unrelated setting changes, and
that depends on which program loads a file rather than on the file, looks
more like heap-layout-dependent corruption than a clean code-generator
threshold. That is a guess, and is labelled as one.

## Root cause

The fix was already in the tree, switched off for this platform.

`pop/src/arm64/ass.p` assembles a procedure in two passes: one to measure the
code, then allocation, then one to plant it. Instruction *selection* depends
on `_pdr_offset` and `_strsize` — `I_CREATE_SF` plants one instruction when
`(_pdr_offset - 8)` fits in a `sub` immediate (under 4KB) and two when it does
not, and PB-relative displacements pick different load forms. So the measuring
pass must run with the *real* offsets, or it measures a different instruction
stream than the one that gets planted.

There is a Pass 0b that re-measures with the real values. It was wrapped in
`#_IF DEF DARWIN`, with a comment that says exactly what would happen
otherwise:

> observed as the ML-lexer SIGILL (trailing pool landed 4 bytes off for a
> procedure with a >4KB structure table). **Latent on ELF too**, but only
> Darwin's high addresses (heap 2**39, seed 2**32) force pooled literals
> everywhere, so it is gated for this port.

It was latent on ELF, and a large vector literal is what wakes it: a few
hundred floats push the structure table past 4KB, instruction selection
changes between measuring and planting, and the planted code runs off its own
end into the literal pool that follows it.

That also explains the shape of the symptom. The disassembly at the fault is a
complete frame unwind with no `ret` after it:

```
0xe18574:  ldr x30, [sp, #8]
0xe18578:  ldr x20, [sp, #16]
0xe1857c:  add sp, sp, #0x10
=> 0xe18580: .inst 0x00e0a670 ; undefined     <- a 64-bit pointer, not code
```

and the PC (`0xe18580`) is past the end of the binary's segments (text ends
`0x5E3A38`, data `0xDEDA08`), i.e. in heap-resident generated code.

## The fix

Remove the `#_IF DEF DARWIN` gate so Pass 0b runs everywhere. The two
invariant checks that guard it — `[ass-diverge]` and `[pool-diverge]` — were
likewise Darwin-only and are now unconditional, because neither the invariant
nor the damage is platform-specific.

After the fix, on the Pi:

```
big1000.p   ok 1000      (was SIGILL)
q600.p      ok 600       (was SIGILL)
q2000.p     ok 2000      (was SIGILL)
weights     loaded       (was SIGILL)

test_primitives.p    41/41
validate-raspi5.sh   13/13  PORT VALIDATED
```

Darwin is unaffected: Pass 0b already ran there, so removing an always-true
condition changes nothing. x86-64 never compiles this file.

## What was ruled out first, and how

Three plausible explanations were tested and discarded before the real one was
found. Recording them because each cost a rebuild and the next person should
not repeat them:

* **Missing instruction-cache maintenance.** ARM has a non-coherent I-cache
  and x86-64 does not, which fits "works on x86, fails on ARM" neatly. But
  both arm64 ports already flush — Linux through GCC's `__clear_cache`, Darwin
  through a clamped helper in `c_core.c`.
* **Literal-pool position diverging between passes.** The `[pool-diverge]`
  check was enabled on ELF and does not fire on the reproducer.
* **Total code size diverging between passes.** The `[ass-diverge]` check was
  enabled on ELF and does not fire either.

The last two are worth keeping in mind: the invariants they guard hold even
while the bug reproduces, so the divergence Pass 0b prevents is in instruction
*selection* within a pass, not in the totals those checks compare.

## Note on the earlier size measurements

The non-monotonic band recorded while this was open (500 passes, 550–2500
fail, 3000+ passes) was measured before the cause was known. It is consistent
with a 4KB structure-table threshold interacting with literal-pool placement,
but the exact boundaries were never explained and are not worth re-deriving
now that the defect is gone.

## Why it is not currently blocking

`vision.p` no longer emits weights as Pop-11 source. Weights are data, not
code: they are written as plain numbers and read at run time with
`line_repeater` and `strnumber`. That is the right mechanism regardless —
making the compiler build a 4096-element literal to get 4096 numbers into a
vector is wasteful — and it sidesteps this entirely. All three machines load
the data file and agree on the output to six decimal places.

## Caveat worth keeping in view

This Pi's tree was rebuilt on 2026-09-18 after carrying a stale
`pop/src/arm64/aarith.s` (see `random-int-64bit.md`). It passes
`test_primitives.p` 41/41 and `validate-raspi5.sh` 13/13, but neither suite
exercises large literals. So this may be a genuine aarch64-Linux code
generator bug, or an artefact of that particular build. Distinguishing them
needs a clean rebuild, or a second aarch64 Linux machine — neither of which
was available when this was found.



## riscv64 had the same defect, and the same fix works

The regression test added to `tools/tests/test_primitives.p` found it
immediately: riscv64 died with SIGILL compiling the same large literal.
`pop/src/riscv64/ass.p` carried an identical Pass 0b behind an identical
`#_IF DEF DARWIN` — on a port that never runs on Darwin, so the mitigation
had always been dead code there.

Ungating it fixes riscv64 too: `test_primitives.p` now passes 46/46 on
machine1, and `validate-riscv64.sh` is 14/14.

Getting there took two false conclusions, both recorded because each looked
convincing:

**"It is a bootstrap problem."** The first attempt failed with `popc`
segfaulting through `pop/src`, which fit a tidy story — compiling the
previously-preprocessed-out block makes the procedure bigger, and the
compiler doing the compiling still has the bug. Reverting did not clear it,
which seemed to confirm the tree could not rebuild itself.

The real cause was neither. That port's `corepop` dates from before the
2026-08-15 `I_CHECK` fix (`userstack-growth-aslr.md`), so the bootstrap
binary still needs ASLR disabled. The Makefile never does that:
`DO_COMMAND = ${ABS_BUILD}/poplog`, no `setarch`. Building as

```
setarch -R make all
```

works. Without it, `popc` segfaults with no output at all; with it, the same
command compiles cleanly. Nothing about the source was at fault.

**"The fix does not work on riscv64."** With the build finally succeeding,
the SIGILL persisted — and `strings target/pop/basepop11` could not find the
new diagnostic, while `target/obj/src.olb` could. That machine's Makefile was
the version *without* the `.olb` cleanup, so `poplibr` had been accumulating
members: six copies of one `ass.p` string in the library where the Pi had
two, and the link kept picking a stale one. Exactly
`stale-olb-shadows-rebuild.md`, still live on that host months after the fix
landed in the repo.

Applying that Makefile fix, removing `stamp_srclib` to force the library to
be rebuilt, and building under `setarch -R` brings the stale count back to
two and puts the change in the binary.

### For anyone rebuilding machine1

* Build with `setarch -R make all` until its `corepop` is regenerated. A
  plain `make all` segfaults in `popc` with an empty log, which looks like a
  source problem and is not one.
* Its Makefile needed the `.olb` cleanup from `stale-olb-shadows-rebuild.md`
  applied by hand; the tree is not a git checkout and inherits nothing.
* A changed source file is not enough to force the library to be rebuilt if
  `stamp_srclib` is newer. Remove the stamp.
* After the rebuild: `validate-riscv64.sh` 14/14, `test_primitives.p` 46/46,
  `test-libs.sh` 12/14 — the two failures are `test_fileutils` and
  `test_zmachine`, the known `aarch64-stat-layout` bug.

