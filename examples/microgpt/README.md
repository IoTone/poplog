# microgpt — a GPT in pure Pop-11

A port of [@karpathy's `microgpt.py`](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95):
train a small transformer and sample from it, with **no dependencies at
all** — no library, no C shim, no BLAS. Scalar autograd, multi-head
attention, Adam and sampling, in **345 lines** of Pop-11 (451 in the file,
less 56 comment lines and 50 blanks).

```sh
./poplog basepop11 examples/microgpt/microgpt.p </dev/null        # 1000 steps
./poplog basepop11 examples/microgpt/microgpt.p 200 </dev/null    # fewer
./poplog basepop11 examples/microgpt/microgpt.p 1000 mydata.txt </dev/null
```

The dataset (32,033 names) is fetched to `input.txt` on first run, exactly as
the original does. Point it at any file of one-item-per-line text and it will
learn that instead — a list of robot callsigns, say.

## What it is

Code lines per section, comments and blanks excluded:

| Part | Lines | What it does |
| --- | ---: | --- |
| `Value` + `v_backward` | 53 | Scalar reverse-mode autograd: every node holds its value, gradient, children and the local derivative w.r.t. each child |
| `gpt` (incl. attention + MLP) | 90 | Token + position embedding, rmsnorm, multi-head causal attention with a KV cache, MLP, residuals, LM head |
| parameters + `matrix` | 38 | The `state_dict`, word-keyed, and gaussian init |
| `train` | 35 | Cross-entropy over one document per step |
| `generate` + `sample_from` | 28 | Temperature sampling |
| dataset + tokenizer + RNG | 47 | Fetch, shuffle, vocabulary, Box–Muller |
| `adam_step` + `init_adam` | 24 | Adam with bias correction and linear LR decay |
| `microgpt_main` / CLI | 25 | Argument handling and the run banner |
| setup (`popdprecision` etc.) | 5 | The three Poplog defaults that must change |
| **total** | **345** | |

Following GPT-2 with the original's simplifications: rmsnorm instead of
layernorm, no biases, ReLU instead of GeLU.

### Why it is 2.2x the Python

The original is 154 code lines (199 in the file) to this port's 345, and the
difference is almost entirely *notation*, not work done. Both build the same
61,104,992-node graph and run the same arithmetic. Where the lines go:

* **No operator overloading.** Python defines 11 dunders in 17 lines —
  `__add__`, `__mul__`, `__pow__`, `__radd__`, `__truediv__`, … — and then
  writes `wi * xi`. Pop-11 has the same ops as named procedures and writes
  `v_mul(wi, xi)`, so every call site is longer and each op is its own
  `define`.
* **No comprehensions, `sum()` or slicing.** `linear` is one line in Python;
  here it is `dot` plus `linear` with explicit loops. `q[hs:hs+head_dim]`
  becomes indexing at `hs + j`.
* **The KV cache is preallocated.** Python appends to growing lists and
  slices them; this uses fixed vectors and an offset, which costs lines and
  saves allocation.
* **Declarations are explicit.** Every procedure declares its `lvars`.
* **It does a little more.** The CLI, the dataset fetch, the graph-node
  counter and the `rand_int` workaround have no counterpart in the original.

Section by section, measured the same way on both files:

| | Python | Pop-11 |
| --- | ---: | ---: |
| autograd (`Value` + backward) | 38 | 53 |
| `gpt` | 33 | 90 |
| `linear` / `softmax` / `rmsnorm` | 11 | (inside the 90) |
| training loop | 24 | 35 |
| inference | 14 | 28 |
| **whole file** | **154** | **345** |

The autograd core is 53 against 38 — close, because it is mostly arithmetic
either way. `gpt` is where the ratio really lives: 33 against 90, and the
Python 33 excludes the 11 lines of `linear`/`softmax`/`rmsnorm` that a
Pop-11 reader sees expanded into loops. Read it as a difference in surface
syntax between a language with operator overloading, comprehensions and
slicing and one without — not as a measure of either language's fitness for
the task. The runtime comparison is in "Speed" below, and it goes the other
way.

Defaults match the original: `n_layer=1`, `n_embd=16`, `n_head=4`,
`block_size=16`, 4,192 parameters, 1000 steps, Adam at `lr=0.01`.

## Poking at it from a live session

Everything is a global procedure, so the model is open to inspection while
it runs — which is the point of doing this in Poplog rather than as a script:

```sh
popsession start --name gpt
popsession send --name gpt -c 'vars microgpt_lib = true;'   # suppress auto-run
popsession send --name gpt -f examples/microgpt/microgpt.p
popsession send --name gpt -c "microgpt_main(300, 'examples/microgpt/input.txt');"
popsession send --name gpt -c 'generate(10, 0.8);'          # sample again, hotter
popsession send --name gpt -c 'train(300);'                 # ...and train some more
popsession checkpoint --name gpt trained.psv                # freeze the weights
```

`checkpoint` writes the whole heap — the trained parameters *and* every
compiled procedure — so `popsession restore` brings a trained model back in
milliseconds with no serialisation format to define.

## Speed

Against the original on the same machine (Apple M-series, 1000 steps,
identical hyperparameters), building the same 61,104,992 autograd nodes.
Median of three runs each; both were stable to within 0.5%:

| | run 1 | run 2 | run 3 | median |
| --- | --- | --- | --- | --- |
| `microgpt.py` (CPython 3.14.0) | 35.76 s | 36.02 s | 36.00 s | 36.00 s |
| `microgpt.p` (Poplog) | 12.59 s | 12.51 s | 12.60 s | **12.59 s** |

**2.86x faster**, wall clock. About 4.6 million graph nodes per second,
allocated, differentiated and collected. No vectorisation on either side —
this is scalar autograd in both, so it is a fair comparison of the two
runtimes rather than of two linear-algebra libraries.

## Five Poplog traps this ran into

All five are silent: the program runs and produces plausible nonsense.

1. **`popdprecision` is false by default**, so `**`, `log`, `exp` and `sqrt`
   return *single*-precision decimals. Set `true -> popdprecision`.
2. **Trig takes degrees by default.** `cos(2*pi*u)` in the Box–Muller
   transform returns ≈1.0 for every input, so every "gaussian" initial
   parameter came out positive and the logits blew up to ±25. Set
   `true -> popradians`. The tell was parameter RMS 0.113 ≈ 0.08·√2 instead
   of 0.08.
3. **The default heap ceiling is 1.5M words (12 MB)** and one training step
   allocates straight through it. Raise `popmemlim`.
4. **A `recordclass` prints its whole subgraph.** One `Value` shown as a
   mishap culprit dumps tens of thousands of nodes and the real error scrolls
   away. Give the key a `class_print`:

   ```pop11
   define print_value(v); printf('<V %p>', [% v_data(v) %]) enddefine;
   print_value -> class_print(Value_key);
   ```
5. **`random(n)` returned `n` every single time** on aarch64 and riscv64, so
   the Fisher-Yates shuffle here silently did nothing and the model trained on
   the first 1000 lines of a sorted corpus. This one was a real engine bug,
   not a misuse — a mis-ported `_posword_mul_high`, now **fixed in this tree**:
   [`docs/bugs/random-int-64bit.md`](../../docs/bugs/random-int-64bit.md).
   This file still draws integers through the float path, so it behaves the
   same on an engine that predates the fix:

   ```pop11
   define rand_int(n) -> k; intof(random0(1.0) * n) + 1 -> k enddefine;
   ```

   It was the training curve that gave it away: loss fell normally, but the
   trained model scored 3.12 on held-out data against `log(27) = 3.296` for a
   model that has learned nothing, and every sample began with the same
   letter.

Two things Pop-11 gave for free, on the other hand. `newproperty` matches
keys by **identity**, which is exactly Python's `set()` of graph nodes — the
`visited` set in the topological sort needed no thought. And `{% ... %}`
builds a vector from whatever a loop leaves on the open stack, which is what
every layer in `gpt` is written with.

## Verifying it

Three checks, all of which this port failed at some point:

1. **Gradient check** against central finite differences — `a*a`, `a**3`,
   `exp`, `log`, `relu`, `a/(a+1)`, `log(exp(a)*a)`, including the shared-node
   case that tests gradient *accumulation*. All agree to 1e-4.
2. **Initial loss** is 3.27, against `log(27) = 3.296` for a uniform model.
3. **Overfit one document.** The strongest single test: 100 Adam steps on the
   single name `emma` takes the loss from 3.20 to 0.000023. If autograd or
   the optimizer is wrong this cannot happen — and it is what proved the
   model was fine and sent me looking at the data pipeline, where the bug was.

Sample output after 1000 steps (~13 s), temperature 0.5:

```
onizi  sharen  janyat  lemik   salay   arannla riley   lesth
janfyn anlian  aman    riisa   casan   radan   kareli  rele
kelenn marie   maria   eria
```
