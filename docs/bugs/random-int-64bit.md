# random(n) and random0(n) return a constant on aarch64 and riscv64

Found 2026-09-16 while porting @karpathy's `microgpt.py` to Pop-11
(`examples/microgpt/`): a textbook Fisher-Yates shuffle written with
`random(i)` left the vector in its original order, and the model trained
on the first 1000 lines of a sorted corpus instead of a random sample.
**Fixed** 2026-09-16 (see "Fix" below); verified on all three affected
platforms.  Pre-existing; nothing in the book or examples work touches this
code.

## Symptom

`REF * NUMBERS` documents the contract:

>     random0(int_or_float) -> random
>         ... the range of the result is 0 <= random0 < int_or_float
>     random(int_or_float) -> random
>         Same as random0, except that whenever the latter would return 0
>         or 0.0, the original argument int_or_float is returned instead.
>         Hence the range of the result is ... 1 <= random <= int_or_float
>         for an integer.

For an integer argument, neither holds.  `random0` returns 0 every time,
and `random` therefore returns its own argument every time:

    random(10)     x15 =>  {10 10 10 10 10 10 10 10 10 10 10 10 10 10 10}
    random0(10)    x10 =>  {0 0 0 0 0 0 0 0 0 0}
    random0(1000)   x6 =>  {0 0 0 0 0 0}

The **float** path is correct, and so is the **bigint** path.  The break is
at exactly 2**24:

| call | result |
| --- | --- |
| `random0(16777215)` (2**24 - 1) | `{0 0 0}` |
| `random0(16777216)` (2**24) | `{0 0 0}` |
| `random0(16777217)` (2**24 + 1) | `{1045773 5480055 2452914}` — correct |
| `random0(2**40)` | `{484100889170 291222286430 449486208259}` — correct |
| `random0(1.0)` | uniform; mean 0.4974 over 20,000 draws, flat 10-bin histogram |

## Platforms

**This is a port regression in this fork's two new back-ends, not an
upstream bug.**  x86-64 — the reference platform, and where CI runs — is
correct:

| platform | host | `random0(1000)` x6 |
| --- | --- | --- |
| Linux **x86-64** | `red5buntu` | `{324 830 766 800 990 674}` — correct |
| macOS **arm64** | this machine (and the released `pop11-skill` tarball) | `{0 0 0 0 0 0}` |
| Linux **aarch64** | `raspi5` | `{0 0 0 0 0 0}` |
| Linux **riscv64** | `machine1` | `{0 0 0 0 0 0}` |

ARM32 and i386 are correct by construction (see below).  That x86-64 is
clean is the reason this survived: every gate, every acceptance suite and
all of CI run on the one platform where the routine works.

## What it breaks

Everything that draws an integer.  In-tree callers:

| file | effect |
| --- | --- |
| `pop/lib/auto/oneof.p` | `oneof([a b c d e])` returns `e` — the **last** element — every time |
| `pop/lib/auto/shuffle.p` | `shuffle([1 2 3 4 5 6])` returns `[6 1 2 3 4 5]`, the same rotation on every call |
| `pop/lib/lib/zmachine_ops.p` | the Z-machine `random` opcode; games get no randomness at all |
| `examples/notebooks/teach/random.ipynb` | the teaching notebook demonstrates `repeat 10 times random(5) => endrepeat` and prints ten 5s |

Measured:

    oneof([a b c d e]) x8  : {e e e e e e e e}
    shuffle([1 2 3 4 5 6]) : [6 1 2 3 4 5]
    shuffle again          : [6 1 2 3 4 5]
    random(5) x10          : {5 5 5 5 5 5 5 5 5 5}

## Cause

`_posword_mul_high` has a **32-bit contract**, and the aarch64 and riscv64
ports implemented it as a 64-bit operation.

`pop/src/random.p`, the small-integer path:

```pop11
lconstant _SIMPLE_LIM = _shift(_1, _:RANSEED_BITS _sub _7);
...
    ;;; return the overflow of seed * _n from RANSEED_BITS
    _posword_mul_high(Random_genseed(), _n) -> _n ;
    _pint(_n)
```

`RANSEED_BITS` is derived from the width of a C **`int`**, not of a machine
word (`pop/src/numbers.ph:63`):

```pop11
RANSEED_BITS = _pint(##(1)[_1|int]) - 1,     ;;; = 31 where int is 32 bits
```

and `Random_genseed` truncates the seed to a signed C `int` whenever
`sizeof(int) /= sizeof(word)` — which is exactly the 64-bit case:

```pop11
#_IF ##(i)[_1|w] /= _1
    ;;; truncate to a signed int for actual use
    lstackmem -i _tmp;
    _seed -> _tmp!(-i);
    _tmp!(-i) -> _seed;
#_ENDIF
```

So the seed carries at most 31 bits.  `_posword_mul_high` is then expected
to shift it left by one (to a full 32 bits) and return the high half of a
**32-bit** product.  Every correct port does exactly that, and the x86-64
source says so in as many words:

```asm
;;; Helper for random number generator
;;; This is really 32-bit code!                <-- pop/src/x86_64/aarith.s
DEF_C_LAB (_posword_mul_high)
    movl    (%USP), %eax
    movl    8(%USP), %edx
    shll    $1, %eax
    imull   %edx                               ;;; 32x32, high half in %edx
    movq    %rdx, (%USP)
```

ARM32 does the same with `umull` (32x32 -> 64, high word in `r1`), and
i386 with `imull`.

The two new ports translated that literally into the host's register
width, which is the natural reading of "multiply two words, return high
word" — and is wrong:

```asm
    lsl   x3, x0, #1        ;;; pop/src/arm64/aarith.s
    umulh x1, x3, x2        /* high 64 bits of unsigned multiply */

    slli  a3, a0, 1         ;;; pop/src/riscv64/aarith.s
    mulhu a1, a3, a2        /* high 64 bits (unsigned) */
```

With a seed below 2**32 and any `n` below `_SIMPLE_LIM` = 2**(31-7) =
2**24, the product is at most 2**56 and never reaches bit 64 — so the high
64 bits are always zero, and `random0` always returns 0.

The exact position of the observed boundary confirms it: the routine is
not merely biased, it returns 0 for every argument the small-integer path
handles, and the first correct value appears at the first argument routed
to `Bigint_random` instead.

## Workaround

Go through the float path, which is correct:

```pop11
define rand_int(n) -> k;            ;;; uniform in 1..n
    intof(random0(1.0) * n) + 1 -> k
enddefine;
```

`examples/microgpt/microgpt.p` uses exactly this, and notes why.

## Fix

Two `aarith.s` routines, and nothing else.  `_posword_mul_high` must take
the high half of a **32-bit** product, as x86-64, i386 and ARM32 all do.

`pop/src/arm64/aarith.s`:

```asm
    lsl   x3, x0, #1        /* seed*2 -- still fits in 32 bits */
    umull x1, w3, w2        /* 32x32 -> 64 unsigned, the full product */
    lsr   x1, x1, #32       /* high half of the 32-bit product */
```

`pop/src/riscv64/aarith.s` (both operands are below 2**32, so a plain
64-bit `mul` holds the product exactly):

```asm
    slli a3, a0, 1
    mul  a1, a3, a2
    srli a1, a1, 32
```

Verified after rebuilding, on every platform the bug touched:

| platform | `random0(1000)` x6 | `oneof` x8 | `random(5)` x10 |
| --- | --- | --- | --- |
| macOS arm64 | `{890 673 115 814 704 607}` | `{d c e d c c d c}` | varied |
| Linux aarch64 (`raspi5`) | `{974 153 540 36 626 534}` | `{d e b e c b e d}` | `{2 3 5 3 5 3 1 1 3 4}` |
| Linux riscv64 (`machine1`) | `{773 245 56 841 243 904}` | `{e c d b a b a b}` | `{2 4 2 2 1 3 3 4 5 5}` |
| Linux x86-64 (`red5buntu`) | untouched — was already correct | — | — |

`shuffle` now returns a different permutation on every call on all three.
Regression: all 14 library suites green on macOS arm64, plus 12/12
`validate-msilicon.sh` gates.  On `raspi5` the four suites that fail
(`test_zmachine` and friends) fail identically before and after — they are
the separate, documented `sys_file_stat` bug
([`aarch64-stat-layout.md`](aarch64-stat-layout.md), which names
`zm_load_story` failing with exactly "10380 4096").

**Getting the fix into a built tree took longer than writing it**, because
a stale `target/obj/src.olb` shadows any rebuilt `pop/src` object — the
engine relinks, reports success, and keeps the old machine code.  That is
its own bug, now fixed in `Makefile.in`:
[`stale-olb-shadows-rebuild.md`](stale-olb-shadows-rebuild.md).

Worth considering separately, and *not* as part of this fix: a 31-bit
linear congruential seed is short for anything statistical, and
`Random_genseed`'s truncation to a C `int` is what makes it so.  Widening
the generator is a real improvement but a behaviour change on every
platform, so it should not ride along with a port correction.

Left deliberately alone: a 31-bit linear congruential seed is short for
anything statistical, and `Random_genseed`'s truncation to a C `int` is
what makes it so.  Widening the generator is a real improvement but a
behaviour change on every platform, so it should not ride along with a port
correction.

The acceptance test now exists: `tools/tests/test_primitives.p`, 31 checks,
run by `tools/test-libs.sh`.  See "What got this past the tests" below.

## What got this past the tests

Not a flawed test case — a missing layer, and a reference platform that
masks the fault.

**1. CI runs where the bug isn't.**  x86-64 is the reference platform and
the only one the `docs` workflow builds on.  The routine is correct there.
No amount of x86-64 testing could have found this.

**2. There is no test layer for core primitives.**  The tree tests two
things:

| layer | what exists | what it asserts |
| --- | --- | --- |
| platform validation | `validate-msilicon.sh`, `validate-raspi5.sh`, `validate-riscv64.sh` — 8-14 gates each | the system boots, the four languages run, nothing segfaults |
| library acceptance | `tools/tests/*.p` — 418 checks over 13 files | libraries written *in* Pop-11 behave |

Nothing tests the primitives the libraries stand on.  Of the **28
hand-written arithmetic helpers** in `pop/src/<arch>/aarith.s` —
`_posword_mul_high`, `_pmult_testovf`, `_bgi_mult`, `_bgi_div`,
`_quotient_estimate`, `_rshift`, … — **zero** are named by any test or
validation script.  They are covered only incidentally, by whatever the
language front-ends happen to exercise while booting.

**3. The gates prove "runs", not "computes".**  Gate 1 of
`validate-msilicon.sh` is `2 + 2`, `sq(9)`, and a `for..in_vector`.  A
broken `_posword_mul_high` passes all three.  The suite already knows this
distinction exists — gate 8 is "external-call FP ABI (multi-float exacc)",
which is there precisely because linking successfully does not mean
computing correctly.  There is no equivalent gate for the integer
arithmetic helpers.

**4. A test suite did exercise the broken path, and passed.**
`tools/tests/test_zmachine.p` has 98 checks and the Z-machine implements
the `random` opcode over `random(r)` (`zmachine_ops.p:689`).  It passes,
because it asserts on transcripts of deterministic play — and a constant
generator makes such transcripts *more* reproducible, not less.  The
breakage is camouflaged by the test design.

**5. The missing assertion is statistical.**  Every assertion in the tree
has the shape *fixed input -> expected output*.  `random(10)` returning
`10` satisfies every type and range check that shape can express: it is an
integer, and it is within `1..10`.  Uniformity is the only property that
distinguishes a working generator from a broken one, and nothing in the
tree asserts a distribution.

### Suggested gates

- **A core-primitives suite**, `tools/tests/test_primitives.p`, run by each
  `validate-*.sh`: the arithmetic helpers against known-answer vectors, and
  `random0(n)` over a few thousand draws binned for flatness.  Known-answer
  vectors are the point — they can be generated once on x86-64 and then
  asserted identically on every port, which is exactly the comparison that
  was missing here.
- **A cross-port differential gate.**  Three ports now disagree with the
  reference on a routine that boots, links and passes every existing gate.
  Any check that ran the same expression on x86-64 and on the new port and
  diffed would have caught this on the first run.
- Grep discipline for the porting checklist: `pop/src/x86_64/aarith.s`
  carries the comment `;;; This is really 32-bit code!` directly above the
  routine that was mis-ported.  The warning was already written down;
  nothing made a porter read it.  `PORTING-POPLOG.md` should list the
  routines whose contract is narrower than the machine word.

## Found again on a third machine, 2026-09-18

The Raspberry Pi (DietPi, aarch64) failed 9 of the 41 checks in
`tools/tests/test_primitives.p` — every one of them a `random` check — because
its tree still carried the pre-fix `pop/src/arm64/aarith.s`. The fix had been
in the repository for weeks.

It survived there because that machine is not a git checkout. It is a
hand-copied source tree (`~/poplog-ci`, `target/` build layout, built
2026-08-14) that no CI job touches, so nothing ever told it the world had
moved. Nobody had run a test on it either, which is the part worth noticing:
the bug was not hiding, it had simply never been looked for.

Repair, for the next stale tree:

1. Copy in the fixed `pop/src/arm64/aarith.s`.
2. Apply the two `Makefile` fixes as well — `SYSCOMP_SRC` must include
   `pop/src/${POP_arch}/*.s` or make never notices the `.s` changed, and the
   `.olb` halves must be removed or a stale member shadows the rebuild
   (`docs/bugs/stale-olb-shadows-rebuild.md`). Patch both `Makefile` and
   `Makefile.in` textually; `configure` only substitutes `@@VAR@@`
   placeholders, so re-running it is unnecessary and risks losing the
   machine's build flags.
3. `make all`, then verify through the *saved image* and not only
   `basepop11` — `random` reaching a `.psv` is the thing users run.

Afterwards: 41/41 on `test_primitives.p`, and 13/13 on
`tools/validate-raspi5.sh` (PORT VALIDATED, console core).

The general lesson is the one this file keeps teaching from a new angle: a
machine that is never tested is not a machine that is working, it is a machine
whose state is unknown. The test suite makes that cheap to settle — it took
one command to find this and one rebuild to fix it.
