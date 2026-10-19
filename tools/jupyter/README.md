# Pop-11 Jupyter kernel

A thin adapter (2030plan 1.3): each notebook cell is one `popsession
send` into a persistent Poplog engine, so the hard parts — FIFO stdin,
sentinel framing, mishap survival — are the pop11 skill's field-proven
machinery. Defines are native-compiled as cells run and survive between
cells; a mishap shows its diagnostics red and the session lives on. The
🌈 line after each cell is the real wall-clock cost.

## Run a notebook

Prereqs: the pop11 skill installed (`install.sh` or the curl one-liner)
and [uv](https://docs.astral.sh/uv/). Then, from a checkout:

```sh
tools/jupyter/lab.sh
```

That is the whole thing. It syncs the environment, registers the kernel
and opens `examples/notebooks/` in JupyterLab; pick the **Pop-11** kernel.
A few seconds once uv's cache is warm. Nothing needs to be on your `PATH`
and nothing is installed outside this directory.

```sh
tools/jupyter/lab.sh examples/notebooks/pop11-live.ipynb   # straight to one
tools/jupyter/lab.sh --console                             # terminal REPL
tools/jupyter/lab.sh --execute --inplace nb.ipynb          # headless, in place
```

The environment is a locked uv project in this directory —
`pyproject.toml` and `uv.lock`, synced with `--frozen` — so you get the
same Jupyter the committed notebook outputs were produced with. It pins
both halves on purpose, because **a kernel is not a frontend**:
`ipykernel` is the engine side, while `jupyter lab` comes from
`jupyterlab` and `jupyter console` from `jupyter-console`, and neither is
a dependency of `ipykernel`. Installing only `ipykernel` leaves a
correctly registered Pop-11 kernel with nothing on the machine able to
open a notebook — which is what used to happen here, with the symptom
`zsh: command not found: jupyter`.

### Without uv, or with a Jupyter of your own

`install-kernel.sh` is the kernel half on its own and needs no uv. It
registers the **Pop-11** kernelspec in your per-user Jupyter directory,
so *any* frontend on the machine lists it — JupyterLab, `jupyter
console`, VS Code notebooks — whatever python the kernel itself runs
under. It picks that python in this order:

| | |
| --- | --- |
| `$POP11_KERNEL_PYTHON` | used as given; nothing installed into it |
| a frontend on `PATH` **and** a `python3` with `ipykernel` | already complete, so nothing is installed |
| uv | `uv sync` this directory (the normal path, and what `lab.sh` uses) |
| no uv | a plain venv at `~/.cache/pop11-skill/jupyter-venv`, with pip, plus `jupyterlab` if you have no frontend at all |

It ends by printing the command to run next. **Read that line rather than
typing `jupyter lab`**: if the frontend is one of the two venvs, that venv
is deliberately not on your `PATH`, and a bare `jupyter lab` is exactly
what fails.

Overrides: `POP11_KERNEL_NO_UV=1` skips uv, `POP11_KERNEL_NO_FRONTEND=1`
registers the kernel and installs no frontend, `POP11_SESSION_BIN` points
at a `popsession` elsewhere.

### If `jupyter` is "command not found"

The kernel is almost certainly registered and fine — you simply have no
frontend on your `PATH`. Use `tools/jupyter/lab.sh`, which needs nothing
on `PATH`. To check what is registered:

```sh
tools/jupyter/.venv/bin/jupyter kernelspec list     # expect: pop11
```

To use your own Jupyter instead, install one (`python3 -m pip install
jupyterlab`, or `pipx install jupyterlab`) and re-run
`install-kernel.sh`: the kernelspec is per-user, so an existing
JupyterLab lists **Pop-11** with no further configuration.

Note that the kernelspec records an absolute path to the python that runs
the kernel. Move the checkout and the registered path goes stale — re-run
`install-kernel.sh` (or `lab.sh`, which does it every time) to rewrite it.

## Try it

`examples/notebooks/pop11-live.ipynb` — executed for real through this
kernel (the committed outputs are genuine).

## Files

- `pop11_kernel.py` — the kernel (ipykernel wrapper class, ~150 lines)
- `lab.sh` — sync, register, open; the one command you need
- `install-kernel.sh` — python/frontend resolution + kernelspec registration
- `pyproject.toml`, `uv.lock` — the locked environment (kernel + frontend)
- `teach2nb.py`, `make-cave-nb.py` — the notebook builders
