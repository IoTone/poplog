# laya — typed decisions from Pop-11, answered locally

`lib laya` makes [`lib typesafe`](../typesafe/README.md)'s `ts_eval` answer with
[Laya](https://github.com/mizorewww/laya-mlx), an open-weight decision model, running on
this Mac's GPU through MLX. No key, no network after the first download, about 8–10 ms a
question.

**This is not part of the Poplog release.** Like `typesafe`, it is an out-of-tree
library.

## Why it needs no new API

Laya takes the request the hosted `POST /v1/systemone` takes (state plus a map of
`noul`/`choice`/`score` questions) and returns the same answers. So the call site does
not change. `uses laya` replaces `ts_transport` with one that talks to a
`laya_serve.py --stdio` child process over a pipe:

```pop11
uses laya;      ;;; loads typesafe too, and installs the local transport

lvars answers = ts_eval('I was billed twice. Please refund the duplicate.',
    [[team   ^(ts_choice('Who should handle this?',
                         [[billing false] [technical false] [sales false]]))]
     [refund ^(ts_noul('Does the customer ask for money back?', false, false))]]);

answers('team')('choice') =>            ** billing
answers('team')('probabilities')('billing') =>   ** 0.8893
answers('refund')('noul') =>            ** 0.8355
ts_last_model =>   ** aac6fef/laya-mlx@20aed815fc6acde75733882e7ec0e3f28aeb9717 float16
```

`ts_last_model` names the exact checkpoint commit and precision. Record it beside any
result you keep, because both change probabilities.

Why a child process rather than HTTP or loading MLX into Poplog:

* **No port.** Nothing listens, so nothing on the network can use the model.
* **Its lifetime is Poplog's.** When Poplog exits the pipe closes, and the server exits
  at end of input.
* **A crash stays over there.** If the model process dies mid-call, that call mishaps and
  the next one starts a fresh child (see *Tests*).
* **The cost is small.** Measured: the pipe and JSON add **0.11 ms** to a ~8 ms answer.
  A loopback HTTP server adds 0.41 ms, mostly in the Python server, not in Pop-11.

## Install

You need [uv](https://docs.astral.sh/uv/) on `$PATH`, and Apple Silicon with macOS 14 or
later. The Python side is a uv project in this directory. `pyproject.toml` pins
[laya-mlx](https://github.com/mizorewww/laya-mlx) **unmodified** from PyPI (`0.2.0`,
which is upstream `main` at `0a85951`) and MLX `0.32.2`, and `uv.lock` pins everything
else.

```sh
uv sync --project packages/laya       # optional: the first call would do it anyway
```

Then, from a checkout:

```pop11
extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;
uses laya;
```

On start, `lib laya` runs `uv sync --frozen` in `laya_home` (milliseconds when nothing
changed), then starts `laya_home/.venv/bin/python laya_serve.py --stdio`. It does not use
`uv run`, because uv run stays alive as the server's parent. The child `lib laya` watches
and signals would then be uv rather than the server; E2 found this when `kill -9` left
the real server answering. `laya_home` is the directory `laya.p` was loaded from, so a
checkout needs no configuration. If you copy `laya.p` into `$poplocal/local/auto`, set `LAYA_HOME` to
wherever this directory lives, because the server and its lock file stay here.

The first call creates `packages/laya/.venv`, downloads the checkpoint (about 0.9 GB)
and loads it. Later starts take a couple of seconds. `laya_start()` is called for you on
first use. Call it yourself to take that wait at a moment you choose.

The same server also speaks HTTP, for clients that are not Pop-11:

```sh
uv run --project packages/laya python packages/laya/laya_serve.py --port 8765
```

It answers `POST /v1/systemone` and `GET /v1/health` on loopback with no authentication,
so typesafe pointed at `http://127.0.0.1:8765/v1` works with no key.

## Settings

| variable | default | |
| --- | --- | --- |
| `laya_home` | `$LAYA_HOME`, or where `laya.p` was loaded from | holds `laya_serve.py`, `pyproject.toml`, `uv.lock` |
| `laya_command` | `$LAYA_SERVER` or `false` | `false`: run `laya_serve.py` with uv. A command: run that instead, with the same arguments (tests use a stand-in) |
| `laya_model` | `'aac6fef/laya-mlx'` | Hub id or local directory; `aac6fef/laya-multilingual-mlx` for non-English text |
| `laya_router` | `false` | `true`: choose a checkpoint per call by language, keeping all three loaded |
| `laya_dtype` | `'float16'` | `'float32'` for closer agreement with the reference |
| `laya_extra_args` | `[]` | passed to `laya_serve.py`, e.g. `['--device' 'cpu']` |

Settings are read when the child starts. To change them, call `laya_stop()`, then the
next call starts a new child.

| procedure | |
| --- | --- |
| `laya_start()` / `laya_stop()` | start the child now (waiting for the model to load) / stop it |
| `laya_running()`, `laya_pid()` | |
| `laya_health()` | property with `'status'` and `'model'` |
| `laya_install()` / `laya_uninstall()` | point `ts_eval` here / back at the hosted API |

## What differs from the hosted model

* **Different model, same schema.** Laya and Jev are different models. Their numbers are
  not comparable, and calibrations differ.
* **`output_tokens` is always 0.** Laya generates nothing, so it answers in a single
  forward pass.
* **Answers carry more.** Every answer has `probabilities` and `action`, and a `score`
  answer has `legend`. Read them like any other field.
* **Order matters, so it is kept.** Laya reads choice options as a sequence, and on one
  checkpoint reordering three options changed the pick in 5 of 6 orderings. `ts_choice`
  therefore sends options in the order you wrote them, and `ts_request` keeps question
  order too. This needed `json_object` in `LIB JSON`, which keeps insertion order.
* **No timeout.** A call blocks until the model answers. `ts_timeout` does not apply.

## Tests

```sh
sh tools/test-libs.sh packages/laya/tests/test_laya.p
```

26 checks, with no model and no MLX. `tests/fake_laya_server.py` speaks the same
protocol with canned answers, and can be told to fail. The checks cover:

* answers through `ts_eval`
* options arriving in written order
* a 422 that keeps the child
* a crash mid-call that forgets it and restarts on the next call
* install and uninstall
* a missing command, which fails before forking. When exec fails in
  `run_unix_program`'s child, a caller's mishap handler can catch it there, and the child
  then runs on as a second copy of Poplog.

The server's own tests use a tiny random checkpoint (15 tests: protocol, errors, HTTP,
the real script as a subprocess, checkpoint identity):

```sh
uv run --project packages/laya pytest
```

Against the real model, `experiments/` checks three things. Its scripts, inputs and
saved outputs are all here, and [RESEARCH.md](RESEARCH.md) has the full write-up:

* **Same answers as Python.** The validation fixtures through `ts_eval` match Python's
  `Agent.predict` field for field: 63 questions × 3 checkpoints × FP16/FP32, all 2,868
  fields identical.
* **Robustness.** 10,000 sequential calls on one child; a malformed question; `kill -9`
  mid-call.
* **Latency.** A paired measurement of the transport cost.
