# Pop-11 Jupyter kernel

A thin adapter (2030plan 1.3): each notebook cell is one `popsession
send` into a persistent Poplog engine, so the hard parts — FIFO stdin,
sentinel framing, mishap survival — are the pop11 skill's field-proven
machinery. Defines are native-compiled as cells run and survive between
cells; a mishap shows its diagnostics red and the session lives on. The
🌈 line after each cell is the real wall-clock cost.

## Install

Prereqs: the pop11 skill installed (`install.sh` or the curl one-liner)
and `python3`. Then:

```sh
tools/jupyter/install-kernel.sh
```

It does two separate things, and it is worth knowing which is which,
because a kernel and a frontend are not the same package:

1. **The kernel.** Uses your `python3` if it already has `ipykernel`;
   otherwise creates a small venv at `~/.cache/pop11-skill/jupyter-venv`
   and installs `ipykernel` there. Then registers the **Pop-11**
   kernelspec in your per-user Jupyter directory, so *any* frontend on
   the machine can see it — JupyterLab, `jupyter console`, VS Code
   notebooks — whatever python the kernel itself runs under.
2. **A frontend, if you have none.** `ipykernel` is the engine side only:
   `jupyter lab` comes from `jupyterlab` and `jupyter console` from
   `jupyter-console`, and neither is one of its dependencies. If no
   `jupyter` on your `PATH` has a `lab`, `notebook` or `console`
   subcommand, and the script created the venv, it installs `jupyterlab`
   there too. It never installs into a python you supplied yourself; in
   that case it tells you what is missing.

The script ends by printing the command to run. **Read that line rather
than typing `jupyter lab`** — if the frontend is the one in the venv, the
venv is deliberately not on your `PATH`, so the command it prints is an
absolute path:

```sh
~/.cache/pop11-skill/jupyter-venv/bin/jupyter lab examples/notebooks/pop11-live.ipynb
```

Then pick the **Pop-11** kernel. To put that `jupyter` on your `PATH` for
a shell, `. ~/.cache/pop11-skill/jupyter-venv/bin/activate`.

### If `jupyter` is "command not found"

The kernel is registered and fine — you have no frontend, or the only one
is in the venv and not on your `PATH`. Check what is registered and which
frontends exist:

```sh
~/.cache/pop11-skill/jupyter-venv/bin/jupyter kernelspec list   # expect: pop11
tools/jupyter/install-kernel.sh                                 # prints the command to use
```

To use your own Jupyter instead, install it (`python3 -m pip install
jupyterlab`, or `pipx install jupyterlab`) and re-run the script: the
kernelspec is global to your user, so an existing JupyterLab will list
**Pop-11** with no further configuration. `POP11_KERNEL_NO_FRONTEND=1`
registers the kernel and installs no frontend at all.

## Try it

`examples/notebooks/pop11-live.ipynb` — executed for real through this
kernel (the committed outputs are genuine).

## Files

- `pop11_kernel.py` — the kernel (ipykernel wrapper class, ~150 lines)
- `install-kernel.sh` — python resolution + kernelspec registration
