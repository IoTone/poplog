# microgpt — a GPT in pure Pop-11

A port of [@karpathy's `microgpt.py`](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95):
train a small transformer and sample from it, with **no dependencies at
all** — no library, no C shim, no BLAS. Scalar autograd, multi-head
attention, Adam and sampling, in ~440 lines of Pop-11.

```sh
./poplog basepop11 examples/microgpt/microgpt.p </dev/null        # 1000 steps
./poplog basepop11 examples/microgpt/microgpt.p 200 </dev/null    # fewer
./poplog basepop11 examples/microgpt/microgpt.p 1000 mydata.txt </dev/null
```

The dataset (32,033 names) is fetched to `input.txt` on first run, exactly as
the original does. Point it at any file of one-item-per-line text and it will
learn that instead — a list of robot callsigns, say.

## What it is

| Part | Lines | What it does |
| --- | --- | --- |
| `Value` + `v_backward` | ~60 | Scalar reverse-mode autograd: every node holds its value, gradient, children and the local derivative w.r.t. each child |
| `gpt` | ~55 | Token + position embedding, rmsnorm, multi-head causal attention with a KV cache, MLP, residuals, LM head |
| `adam_step` | ~20 | Adam with bias correction and linear LR decay |
| `train` / `generate` | ~60 | Cross-entropy over one document per step; temperature sampling |

Following GPT-2 with the original's simplifications: rmsnorm instead of
layernorm, no biases, ReLU instead of GeLU.

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
identical hyperparameters), building the same 61 million autograd nodes:

| | wall | relative |
| --- | --- | --- |
| `microgpt.py` (CPython 3) | 39.56 s | 1.0x |
| `microgpt.p` (Poplog) | **12.93 s** | **3.06x faster** |

About 4.7 million graph nodes per second, allocated, differentiated and
collected. No vectorisation on either side — this is scalar autograd in
both, so it is a fair comparison of the two runtimes.

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
5. **`random(n)` is broken for integers** on 64-bit builds — it returns `n`
   every single time, so the Fisher-Yates shuffle here silently did nothing
   and the model trained on the first 1000 lines of a sorted corpus. This one
   is a real engine bug, not a misuse:
   [`docs/bugs/random-int-64bit.md`](../../docs/bugs/random-int-64bit.md).
   Draw integers through the float path instead:

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
