# SIGILL compiling large float-vector literals (Raspberry Pi, aarch64)

**Status:** OPEN — reproducible, not diagnosed
**Severity:** high on the affected machine — the process dies, no mishap
**Found:** 2026-09-19, exporting classifier weights as Pop-11 source
**Affects:** the Raspberry Pi's build only. macOS arm64 and Linux x86-64 run
the identical files without complaint.

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

Until then: **do not trust that machine to compile large literal data**, and
prefer reading data over compiling it anywhere it matters.
