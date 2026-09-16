# random(n) and random0(n) are broken for every integer n <= 2**24 on 64-bit builds

Found 2026-09-16 while porting @karpathy's `microgpt.py` to Pop-11
(`examples/microgpt/`): a textbook Fisher-Yates shuffle written with
`random(i)` left the vector in its original order, and the model trained
on the first 1000 lines of a sorted corpus instead of a random sample.
**Not fixed.**  Pre-existing; nothing in the book or examples work touches
this code.

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

Identical output, same 2**24 boundary, on all three 64-bit platforms tested:

| platform | build | result |
| --- | --- | --- |
| macOS arm64 (M-series) | this tree, and the released `pop11-skill` tarball | broken |
| Linux aarch64 (`raspi5`) | this tree | broken |
| Linux riscv64 (`machine1`) | this tree | broken |

Not tested on 32-bit (ARM32, Solaris x86) — see the cause below for why
those are expected to differ.

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

So the seed carries at most 31 bits, while `_posword_mul_high` takes the
high half of a **word**-wide (64-bit) product.  For any `n` below
`_SIMPLE_LIM` = 2**(31-7) = 2**24, the product is at most
2**31 x 2**24 = 2**55, which never reaches bit 64 — so the high word is
always zero, and `random0` always returns 0.

The exact position of the observed boundary is the confirmation: the
routine is not merely biased, it returns 0 for every argument the
small-integer path handles, and the first correct value appears at the
first argument that is routed to `Bigint_random` instead.

On a 32-bit build word size and `RANSEED_BITS` are within one bit of each
other, which is presumably why this survived: the same code returns
something plausible there.

## Workaround

Go through the float path, which is correct:

```pop11
define rand_int(n) -> k;            ;;; uniform in 1..n
    intof(random0(1.0) * n) + 1 -> k
enddefine;
```

`examples/microgpt/microgpt.p` uses exactly this, and notes why.

## Fix, not attempted here

The shift taken by `_posword_mul_high` and the width of the seed have to
agree.  Either widen `Random_genseed` to a full word on 64-bit builds (drop
the `int` truncation, and make `RANSEED_BITS` a word width), or keep the
31-bit seed and take the overflow from bit 31 rather than from the word
width.  The first also lengthens the generator's period, which at 31 bits
is short for anything statistical; the second is the smaller change.

Either way the acceptance test is cheap and belongs in the tree:
`random0(n)` over a few thousand draws for a handful of small `n` should be
flat, and `oneof`/`shuffle` should stop being constant.
