# Research: a Pop-11 extension API for Laya-MLX

Status: **built, measured, and merged into IoTone/poplog `dev`** (2026-10-01). The investigation began 2026-09-22.

This document lives with the code it describes, in `packages/laya/`. It started in a local laya-mlx checkout. Since then the server moved here, and laya-mlx is used unmodified at a pinned version.

Question: how should Poplog programs call Laya's typed decisions running locally on Apple Silicon, and how much of that already exists?

Answer: most of it already existed. [`packages/typesafe`](https://github.com/IoTone/poplog/tree/dev/packages/typesafe) in IoTone/poplog is a Pop-11 client for TypeSafe's hosted Jev model at `POST /v1/systemone`, and Laya takes the same request and returns the same answers. So the extension API is a **local backend behind the existing `ts_*` calls**. It is now built, all in `packages/laya`:

- `laya_serve.py` (stdio and HTTP): a uv project that pins [laya-mlx](https://github.com/mizorewww/laya-mlx) `0.2.0` from PyPI, **unmodified**, and uses only its public API;
- `lib laya`, a `ts_transport` that syncs the uv environment and runs `laya_serve.py --stdio` with its Python as a child process.

Pop-11 gets the same answers as Python, field for field, and the transport adds about 0.1 ms to a ~8 ms answer.

Running MLX *inside* Poplog also works. So does a Pop-11-driven port of the model over MLX's C API, demonstrated for the embeddings and two encoder layers. Neither is needed for speed.

Building it found three bugs that would have given Pop-11 users wrong or unreproducible answers, plus four facts worth knowing about Laya and MLX themselves (§3).

## 1. What was built

### The Python side: `packages/laya` (a uv project)

| Change | Where |
|---|---|
| `pyproject.toml` + `uv.lock`: `laya-mlx==0.2.0` (upstream `main` at `0a85951`, verified file for file), `mlx==0.32.2`; dev group `pytest`, `ruff` | `packages/laya/` |
| `laya_serve.py --stdio`: JSON-RPC 2.0, one message per line, `systemone` and `health` methods; exits at end of input | `laya_serve.py` |
| `laya_serve.py --port N`: `POST /v1/systemone`, `GET /v1/health`, loopback by default, warns if not | same |
| `--router`: language routing across all three checkpoints, all kept loaded | same |
| Errors: malformed question → 422 (`-32602`), anything else → 500 (`-32603`), with `data.status` on stdio; the server keeps serving | same |
| Protocol stdout is isolated: fd 1 is moved to stderr, so warnings and stray prints can't corrupt it | `serve_stdio` |
| `checkpoint(agent)`: id, resolved Hub commit, subfolder and dtype, read from the pinned `Agent`'s own attributes. The server reports it as `model`; laya-mlx itself always says `"laya-rl-agent"` | `laya_serve.py` |
| Tests: 15, including the real script as a subprocess and a real HTTP server, on a tiny random checkpoint | `tests/test_laya_serve.py` |
| Experiments, their inputs (laya-mlx's validation fixtures, saved) and saved outputs | `experiments/`, `experiments/fixtures/`, `experiments/results/` |

### The Pop-11 side (IoTone/poplog, PR #32 and this change)

| Change | Where |
|---|---|
| `json_object()`: an object that keeps insertion order and is applied like a property; also `isjson_object`, `json_object_app`, `json_ordered_objects` (ordered parsing) | `pop/lib/lib/json.p`, `pop/help/json`, `tools/test-json.sh` (+9 cases) |
| `ts_choice` options and `ts_request` questions go out in the order written | `packages/typesafe/typesafe.p` |
| `ts_require_key`, and a loopback `ts_base_url`, mean no key is needed and no `Authorization` header is sent | same, plus README and tests (+6 checks) |
| `lib laya`: stdio transport, per-call `ts_timeout` (a select on the pipe; a late child is killed, never reused), lazy start (`uv sync --frozen`, then `laya_home/.venv/bin/python laya_serve.py`), crash recovery, `laya_install`/`laya_uninstall`, `laya_health` | `packages/laya/laya.p`, `README.md` |
| Offline tests against a stand-in server: 26 checks | `packages/laya/tests/test_laya.p` |

Every Poplog library suite still passes (`tools/test-libs.sh`), as does the JSON acceptance suite (52 cases).

The Pop-11 call site is unchanged:

```pop11
uses laya;
lvars answers = ts_eval('I was billed twice. Please refund the duplicate.',
    [[team   ^(ts_choice('Who should handle this?',
                         [[billing false] [technical false] [sales false]]))]
     [refund ^(ts_noul('Does the customer ask for money back?', false, false))]]);
answers('team')('choice') =>     ** billing
ts_last_model =>   ** aac6fef/laya-mlx@20aed815fc6acde75733882e7ec0e3f28aeb9717 float16
```

## 2. Gaps found and fixed

| # | Gap | Effect before the fix | Fix |
|---|---|---|---|
| G1 | Responses said `"model": "laya-rl-agent"` | `ts_last_model`, the value the typesafe docs say to store, couldn't identify the checkpoint, its revision or its precision | the server reports `checkpoint(agent)` |
| G2 | `ts_eval` required an `apikey_…` key | No local backend could be used, and an existing key would have been sent to it | `ts_require_key`, loopback detection, no header without need |
| G3 | **`ts_choice` sent options in hash order** (`billing, technical, sales, legal, hr` went out as `technical, hr, billing, sales, legal`) | **Different answers.** Laya reads options as a sequence (§3.1): the same text and options could get a different pick from Pop-11 than from Python | `json_object` in `LIB JSON`; `ts_choice` uses it |
| G4 | **`ts_request` sent questions in hash order** | Found by E1: 3 of 63 scores and some probabilities differed from Python in the 4th decimal (§3.2) | `ts_request` uses `json_object` |

G3 and G4 also affect the hosted Jev API. Whether Jev is order-sensitive is unknown, but the client no longer leaves it to chance.

## 3. Findings about Laya and MLX

### 3.1 Choice answers depend on option order

All orderings of the same options, with the same text (`experiments/option_order.py`, saved in `experiments/results/option-order.json`):

| Checkpoint | Options | Orderings agreeing with written order | Largest change in one option's probability |
|---|---:|---:|---:|
| multilingual | 3 | **1 / 6** (picks `billing` or `sales`) | **0.54** |
| multilingual | 5 | 120 / 120 | 0.38 |
| English | 5 | 120 / 120 | 0.28 |
| typed-decisions | 5 | 120 / 120 | 0.10 |

The pick is usually stable, but probabilities aren't. For close calls the pick isn't stable either. Treat the option order as part of the question: keep it fixed, and record it with the result.

### 3.2 A question's probabilities depend on its batch-mates (GPU)

Questions are batched (`batch_size`, default 16), padded to the longest in the batch. On the GPU the same question gets slightly different numbers in different batches. In the `many_questions` fixture, q0 and q18 are the same question; Python gives `confidence` 0.8329 for one and 0.8331 for the other.

Differences are ~1e-4, and in these fixtures no choice pick changed. Two consequences:

- question order in a request is part of reproducibility;
- upstream laya-mlx's own `test_all_primitives_empty_request_and_chunking` (batched vs one-by-one must be identical) fails on the GPU because of this effect. It passes on CPU, which is what its CI runs.

**Measured, 2026-10-03** (`experiments/batch_independence.py`, saved in `experiments/results/batch-independence.json`). The setup is 12 questions and 200 random requests of 2–24 questions, giving 2,529 answers per configuration. Each answer is compared, field by field at laya-mlx's 4-decimal rounding, with the same question asked alone. English checkpoint, M5 Pro.

| Configuration | Answers differing | Largest difference | 1 question | 16 questions |
|---|---:|---:|---:|---:|
| default (batch 16, padded to longest), FP16 | 50.2% | 0.0021 | 9.5 ms | 96 ms |
| padded to a multiple of 64 | 56.0% | 0.0021 | 9.5 ms | 118 ms |
| padded to the full context (512) | 65.6% | 0.0021 | 24.7 ms | 365 ms |
| full context **and** every batch filled to 16 rows | **0%** | 0 | 480 ms | 474 ms |
| **`batch_size=1`** | **0%** | 0 | 9.7 ms | 164 ms |
| default, FP32 | 50.2% | 0.0008 | 11.6 ms | 107 ms |
| default on the CPU, FP32 | 0% | 0 | 97 ms | 1,781 ms |

- **The cause is the shape of the forward pass, not padding.** More padding makes it worse. Only identical shapes (fixed length *and* a fixed number of rows) remove it on the GPU, consistent with kernel selection by shape. The CPU is row-independent.
- **No choice pick changed** in any configuration. The effect is in the 3rd–4th decimal of probabilities and confidence.
- **The exact and practical option is `batch_size=1`.** A single question costs the same, and a 16-question request about 1.7×. With `lib laya`, set `['--batch-size' '1'] -> laya_extra_args`. Fixed shapes would cost ~480 ms per request.

### 3.3 Float32 matmul on this GPU is not IEEE float32 accurate

The input is deliberately hard (512×512, values up to 2.6e5), on an Apple M5 Pro with MLX 0.32.2 (`gpu_matmul_precision.py`):

| | max relative error |
|---|---:|
| GPU float32 | **1.2e-3** |
| CPU float32 | 2.3e-6 |

"FP32" results on the GPU are therefore not reference-exact. This is why E4 compares on the CPU to separate port errors from device numerics.

### 3.4 Process and FFI hazards met on the way

- **`uv run` is not exec.** It stays alive as the parent of the Python it starts. Launched through `uv run`, the child `lib laya` holds, and the PID it reports and signals, was uv's. In E2, `kill -9` killed uv while the real server kept answering on the inherited pipes. `lib laya` therefore runs `uv sync --frozen` and then starts the environment's own `python`: uv manages the dependencies, but it is not in the process tree.

- **An untyped `exload` argument passes a Pop-11 integer as an integer**, even when the C parameter is a `double`. It arrives in the wrong register and is read as garbage, silently. In E4 this made encoder layer 1 wrong by up to 16. Pass decimals (`number_coerce(n, 1.0)`), or keep every double parameter's call sites visibly decimal.
- **MLX's safetensors load has no GPU kernel** (`[Load::eval_gpu] Not implemented`). Load on the CPU stream, as Python's `mx.load` does.
- mlx-c passes arrays as one-pointer structs *by value*. The shims pass only the `ctx` pointer and rebuild the struct in C, so Pop-11 never deals with a struct.

## 4. Experiments

Machine: Apple M5 Pro, 48 GiB, macOS 26.4. Poplog `basepop11` built from IoTone/poplog `dev` at `5c93912`.

All results below were **rerun on 2026-10-01 in this package's pinned uv environment**: `laya-mlx==0.2.0` from PyPI and `mlx==0.32.2`. They replace the first runs, which used a local laya-mlx checkout carrying the server. Scripts are in `experiments/`; paths below are relative to it. Run them from the Poplog root with `uv run --project packages/laya python packages/laya/experiments/<script>`.

The first runs shared the machine with an unrelated process at 100% CPU, which is why latency is measured paired (E3): the pairing makes it robust to load.

| # | Question | Result | Evidence |
|---|---|---|---|
| E1 | Does Pop-11 get Python's answers? | **Yes, exactly.** The 16 validation cases (63 questions) through `ts_eval` → `lib laya` → `laya_serve.py --stdio`, for 3 checkpoints × FP16/FP32: **2,868 / 2,868 answer fields identical** to in-process `Agent.predict`, 132 / 132 choice picks, plus equal `usage` and the `model` checkpoint. The first run found G4. | `results/e1-parity.jsonl`; `parity_cases.py`, `parity.p`, `compare.py` |
| E2 | Does the coprocess hold up? | **Yes.** 10,000 sequential calls on one child, all well-formed. A malformed question raised a mishap and the child kept serving. `kill -9` mid-call raised a mishap, and the next call started a new child and answered. No leaked processes. | `results/e2-robustness.txt`; `robustness.p` |
| E3 | What does the transport cost? | Paired per call (client time minus the server's own time for that call), median of 3 rounds × 300 calls: **stdio 0.107 ms P50 / 0.129 ms P95**; HTTP from Pop-11 0.413 / 0.493; HTTP from Python 0.365 / 0.449. So most of the HTTP cost is the Python server, not libcurl or Pop-11. Pop-11 JSON: encode 0.011 ms, decode 0.013 ms. In-process inference for this request: 8.25–8.30 ms P50. (The first run, on a machine at load 4–11, measured 0.16 / 0.54 ms with ~10 ms inference: same conclusions.) | `results/latency.json`; `latency.py`, `latency.p`, `timed_serve.py` |
| E4 | Can Pop-11 drive the model through mlx-c? | **Yes**, for the embeddings and layers 0–1 (global attention; then sliding-window attention with its attention norm), 96 tokens, FP32. The structure is written in Pop-11 over single-op C entry points. On CPU vs Python on CPU: embeddings **bit-identical**, layers within **1.9e-5** of values up to 58 (a few float32 ulps; the rest is MLX's compiled GELU). On GPU: within 0.0023 / 0.0040, **15× smaller** than Python's own GPU-vs-CPU spread (0.038 / 0.059). | `results/e4-*.json`; `encoder_ref.py`, `encoder_layers.p`, `mlx_shim/pm_ops.c` |
| E5 | Can MLX run inside Poplog? | **Yes.** `basepop11` (MAP_JIT, W^X) loaded mlx-c and ran matmuls on GPU and CPU. Doubles crossed the FFI correctly. GPU results print identically to Python MLX's. Afterwards Pop-11 still compiled code and garbage-collected. | `results/e5-mlx-inprocess.txt`; `mlx_inprocess.p`, `mlx_shim/pm_shim.c` |

Reproduce E4/E5: build mlx-c (`main` at `a341b49`, which pins MLX v0.32.2) against this package's MLX:

```sh
MLX=$(uv run --project packages/laya python -c "import mlx.core, os; print(os.path.dirname(mlx.core.__file__))")
cmake -S mlx-c -B mlx-c/build -DMLX_C_USE_SYSTEM_MLX=ON -DBUILD_SHARED_LIBS=ON \
  -DMLX_DIR=$MLX/share/cmake/MLX
cmake --build mlx-c/build
sh packages/laya/experiments/mlx_shim/build.sh mlx-c
```

The build takes seconds, because MLX itself comes from the wheel. This is why `pyproject.toml` pins `mlx` exactly: the shims are built against one MLX.

## 5. Decisions

The options from the first version of this document, now settled by measurement:

| Option | Verdict | Why |
|---|---|---|
| **B. stdio coprocess** (`lib laya`) | **Default.** Built. | 0.11 ms overhead, no port, crash isolation, lifetime tied to Poplog |
| **A. loopback HTTP** (`laya_serve.py --port`) | Built. Use it to share one loaded model across several clients or languages. | 0.41 ms overhead, mostly Python's `http.server` |
| **C. in-process via CPython** | **Don't.** | The doc set a threshold: worth trying only if B added more than ~1 ms. It adds 0.11 ms, about 1.3% of an answer, and C would put Python, Metal and Poplog in one crash domain |
| **D. native port over mlx-c** | Feasible, not justified for speed. | E4 shows the approach works and matches. A full port still needs the remaining 26 layers (the same two patterns), the decision head, calibration, prompt construction, and above all **a tokenizer** (Hugging Face `tokenizers` has no C API). Its value would be independence from Python, not latency: it runs the same MLX kernels |

## 6. Open items

- **laya-mlx is used, not changed.** Upgrading means bumping `laya-mlx` (and `mlx` to match its range) in `pyproject.toml`, `uv lock`, then rerunning E1. E1 is what shows a new version still answers identically through Pop-11. `checkpoint(agent)` reads `model_id`, `model_dir` and `dtype` from `Agent`, so a release that renames those breaks it loudly in the tests.
- ~~`run_unix_program` can clone Poplog~~ Fixed in #35 (2026-10-01): a failed exec now always ends the child (status 127, reason on its own stderr), with a regression suite in `tools/tests/test_run_unix_program.p`. `lib laya` still checks for the command before forking, for a clearer error in the parent. The same fork-then-exec pattern in `pipein`, `pipeout`, `sys_popen`, LIB SHELL and `ptyfork` is unchanged.
- ~~`lib laya` has no timeout~~ Done (2026-10-01): each call is bounded by `ts_timeout`, and startup by `laya_start_timeout`. A child that misses its deadline is killed, not waited for. Waiting is `sys_device_wait` (select) on the pipe, so stdio overhead is unchanged (0.105 ms P50).
- `--router` is tested by a unit test and one live run (Chinese → multilingual, English → English), not by E1.
  - It loads upstream `convaiinnovations/laya`, not the `aac6fef` conversions.
  - Its `health` reports `laya-router`, because no single checkpoint applies.
- Jev's order sensitivity (G3/G4 on the hosted API) is unmeasured.
- ~~§3.2: can padding make answers independent of batch-mates?~~ Measured (§3.2): padding alone makes it worse; `batch_size=1` makes answers exactly independent, at ~1.7× for 16-question requests. It is opt-in, and the default is unchanged.
- If D is pursued, check the tokenizer first: it's the part with no C path and no parity oracle beyond token-by-token comparison.

## 7. Background (unchanged from the first version)

### What Poplog provides

| Facility | Where | Used by |
|---|---|---|
| `http_request` over libcurl | `pop/lib/lib/http_client.p` | typesafe; option A |
| JSON | `pop/lib/lib/json.p` | everything; now with `json_object` |
| JSON-RPC 2.0 framing | `pop/lib/lib/jsonrpc.p` | the stdio protocol follows its "line" framing |
| Child processes with pipe devices | `LIB run_unix_program` | `lib laya` |
| C FFI (`exload`, `exacc`) | `pop/lib/auto/exload.p` | E4/E5 shims, E3's nanosecond clock (`clock_gettime_nsec_np`) |
| Swappable transport | `ts_transport` in typesafe.p | `lib laya` |

### Literature

The upstream README and model card cite no papers. What follows is what bears on this work.

**Laya itself**
- Nandakishor M, *SalesRLAgent: A Reinforcement Learning Approach for Real-Time Sales Conversion Prediction and Optimization*, [arXiv:2503.23303](https://arxiv.org/abs/2503.23303) (Mar 2025). An earlier non-autoregressive RL decision model by the Laya author, which third-party write-ups describe as Laya's predecessor.
- RLCD ("Reinforcement Learning for Calibrated Decisions") is described on the [model card](https://huggingface.co/convaiinnovations/laya) but has no paper. Its basis is strictly proper scoring rules: Gneiting & Raftery, *Strictly Proper Scoring Rules, Prediction, and Estimation*, JASA 2007.

**Architecture reimplemented here (and in option D)**
- Warner et al., *ModernBERT*, [arXiv:2412.13663](https://arxiv.org/abs/2412.13663)
- Marone et al., *mmBERT*, [arXiv:2509.06888](https://arxiv.org/abs/2509.06888)
- Devlin et al., *BERT*, [arXiv:1810.04805](https://arxiv.org/abs/1810.04805)
- Su et al., *RoFormer (RoPE)*, [arXiv:2104.09864](https://arxiv.org/abs/2104.09864)
- Beltagy et al., *Longformer* (sliding-window local attention), [arXiv:2004.05150](https://arxiv.org/abs/2004.05150)
- Shazeer, *GLU Variants Improve Transformer*, [arXiv:2002.05202](https://arxiv.org/abs/2002.05202)

**Decisions, calibration, shortlisting**
- Guo et al., *On Calibration of Modern Neural Networks* (temperature scaling), [arXiv:1706.04599](https://arxiv.org/abs/1706.04599)
- Humeau et al., *Poly-encoders* (joint vs separate encoding; why state encodings aren't reused), [arXiv:1905.01969](https://arxiv.org/abs/1905.01969)
- Reimers & Gurevych, *Sentence-BERT*, [arXiv:1908.10084](https://arxiv.org/abs/1908.10084); Karpukhin et al., *DPR*, [arXiv:2004.04906](https://arxiv.org/abs/2004.04906) (`predict_shortlist`)
- Yin et al., *Benchmarking Zero-shot Text Classification*, [arXiv:1909.00161](https://arxiv.org/abs/1909.00161)

**Performance (the first four are already cited in `docs/MATH_10X_RESEARCH.md`)**
- FlashAttention [arXiv:2205.14135](https://arxiv.org/abs/2205.14135), FastBERT [arXiv:2004.02178](https://arxiv.org/abs/2004.02178), DeeBERT [arXiv:2004.12993](https://arxiv.org/abs/2004.12993), TinyBERT [arXiv:1909.10351](https://arxiv.org/abs/1909.10351)
- DistilBERT [arXiv:1910.01108](https://arxiv.org/abs/1910.01108); Williams et al., *Roofline*, CACM 2009; LLM.int8() [arXiv:2208.07339](https://arxiv.org/abs/2208.07339), GPTQ [arXiv:2210.17323](https://arxiv.org/abs/2210.17323), AWQ [arXiv:2306.00978](https://arxiv.org/abs/2306.00978)

MLX has no paper. Cite it as software: Apple ml-explore, 2023, https://github.com/ml-explore/mlx.

## Sources inspected

- IoTone/poplog `dev`: `packages/typesafe/*`, `pop/lib/lib/{json,http_client,http_server,jsonrpc,fileutils}.p`, `pop/extern/popcurl/popcurl_shim.c`, `pop/help/run_unix_program`, `tools/ffi-float-regression.p`, `tools/test-libs.sh`, `PORTING-ARM64-M-SILICON-OSX.md`, `NOTES-METAL-GRAPHICS-MACOS.md`
- ml-explore/mlx-c `main` at `a341b49`: `mlx/c/{array,ops,fast,io,map,stream,optional}.h`
- This repo: `laya_mlx/{agent,common,model,router,tokenizer}.py`, `benchmarks/{common,validate,worker}.py`, `README.md`
