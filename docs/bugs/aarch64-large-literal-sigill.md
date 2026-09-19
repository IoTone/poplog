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



## riscv64 has the same defect, and cannot be fixed the same way

The regression test added to `tools/tests/test_primitives.p` found it
immediately: riscv64 dies with SIGILL compiling the same large literal.
`pop/src/riscv64/ass.p` carries an identical Pass 0b, with an identical
`#_IF DEF DARWIN` around it — on a port that never runs on Darwin, so the
mitigation has always been dead code there.

Removing the gate does not work, because of a bootstrap problem. The Pass 0b
block is currently *preprocessed out*; compiling it in makes the enclosing
procedure larger, and the compiler that has to compile it is the old one,
which still has the bug. `popc` segfaults part-way through `pop/src`:

```
(cd pop/src && .../poplog popc -c -nosys -od .../target/src riscv64/*.[ps] *.p)
Segmentation fault (core dumped)
make: *** [Makefile:192: stamp_srclib] Error 139
```

Reverting the change does not clear it — the same failure occurs with
unmodified sources, so **that tree could not rebuild itself before this was
touched**. The segfault compiling `pop/src` is plausibly the same defect
biting the compiler while it compiles its own source, which would make the
port unable to regenerate itself at all.

arm64 escaped this only by luck: the same edit compiled cleanly on the Pi and
on macOS, so the new code happened not to cross the threshold during that
build.

Fixing riscv64 therefore needs a bootstrap route — building the fixed
assembler with something that is not itself broken (`corepop`, a
cross-compile, or a staged build). That is not attempted here.

### State of machine1 (riscv64) after this investigation

* `basepop11` runs, and `tools/validate-riscv64.sh` passes 14/14 — PORT
  VALIDATED. The machine is functionally unchanged.
* `target/obj/src.wlb` is gone: `make` removes it at the start of
  `stamp_srclib` and the run then failed. It cannot be regenerated until the
  bootstrap problem is solved, so the tree can run but cannot relink.
* An older `~/poplog-ci` on that box has an intact `src.wlb` from August, but
  against a September `src.olb`. Mixing them is exactly the hazard in
  `stale-olb-shadows-rebuild.md` and was not done.
* `tools/tests/test_primitives.p` now dies on riscv64 at the literal checks,
  taking the other 41 with it. That is the regression test doing its job, but
  it does mean the suite reports nothing on that platform until the port is
  fixed.
