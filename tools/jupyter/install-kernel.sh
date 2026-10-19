#!/bin/sh
# install-kernel.sh — register the Pop-11 Jupyter kernel.
#
#   tools/jupyter/install-kernel.sh
#
# Sets up a python that can run the kernel AND a frontend that can open a
# notebook, then writes the kernelspec so `jupyter lab` / `jupyter console`
# list "Pop-11".  In order of preference:
#
#   1. $POP11_KERNEL_PYTHON, if set -- yours, so nothing is installed into it.
#   2. A complete setup already here: a python3 with ipykernel and a frontend
#      on PATH.  Nothing is installed.
#   3. uv -- `uv sync` the locked project in this directory (pyproject.toml,
#      uv.lock).  Seconds, reproducible, and the normal path.
#   4. No uv: a plain venv at ~/.cache/pop11-skill/jupyter-venv, with pip.
#
# A KERNEL IS NOT A FRONTEND.  ipykernel is the engine side; `jupyter lab`
# comes from jupyterlab and `jupyter console` from jupyter-console, and
# neither is a dependency of ipykernel.  This script used to register the
# kernelspec and then advise `jupyter console --kernel pop11`, on a machine
# where installing the venv had left no jupyter on PATH and no lab or
# console subcommand anywhere -- correct kernel, nothing to run it with,
# and the advice failed with "command not found".  So the frontend is now
# resolved too, and the closing message names a command that exists.
#
# Env overrides:
#   POP11_SESSION_BIN   popsession executable
#                       (default ~/.claude/skills/pop11/bin/popsession)
#   POP11_KERNEL_PYTHON python to run the kernel with (skips all of the below)
#   POP11_KERNEL_NO_FRONTEND
#                       non-empty: register the kernel and install no
#                       frontend, even when this script owns the venv
#   POP11_KERNEL_NO_UV  non-empty: skip uv even where it is installed
set -e

here="$(cd "$(dirname "$0")" && pwd)"
kernel_py="$here/pop11_kernel.py"
popsession="${POP11_SESSION_BIN:-$HOME/.claude/skills/pop11/bin/popsession}"

[ -x "$popsession" ] || {
    echo "install-kernel: popsession not found at $popsession" >&2
    echo "  (install the pop11 skill first, or set POP11_SESSION_BIN)" >&2
    exit 2
}

# `jupyter <sub> --version` exits 0 when the subcommand exists and 1 when it
# does not.  That, not `command -v jupyter`: the jupyter_core launcher comes
# in with ipykernel either way, so the bare binary existing proves nothing --
# which is how a machine with a registered kernel and no frontend went
# unnoticed, and the old closing advice came to fail with "command not found".
have_sub() {           # have_sub <jupyter-binary> <subcommand>
    "$1" "$2" --version >/dev/null 2>&1
}

path_frontend() {      # echo the first usable subcommand of a jupyter on PATH
    command -v jupyter >/dev/null 2>&1 || return 1
    for _s in lab notebook console; do
        if have_sub jupyter "$_s"; then echo "$_s"; return 0; fi
    done
    return 1
}

# ---- resolve a kernel python and a frontend -------------------------------
# $launcher is set only on the uv path, because lab.sh requires uv: suggesting
# it after the pip fallback would hand someone a command that cannot run.
py=""; venv=""; front=""; front_sub=""; launcher=""

if [ -n "$POP11_KERNEL_PYTHON" ]; then
    # Yours: used as given, and nothing is installed into it.
    py="$POP11_KERNEL_PYTHON"
    if front_sub="$(path_frontend)"; then front="jupyter"; fi

elif front_sub="$(path_frontend)" && python3 -c 'import ipykernel' 2>/dev/null; then
    # Already complete -- a frontend on PATH and a python that can host the
    # kernel.  Downloading our own copy of JupyterLab next to a working one
    # would be rude, so this installs nothing.
    py="$(command -v python3)"; front="jupyter"

elif [ -z "$POP11_KERNEL_NO_UV" ] && command -v uv >/dev/null 2>&1; then
    # The normal path: the locked project in this directory, which pins the
    # kernel and the frontend together.  Seconds when uv's cache is warm.
    echo "install-kernel: uv sync $here"
    uv sync -q --frozen --project "$here" >/dev/null
    venv="$here/.venv"
    py="$venv/bin/python3"
    # The kernelspec points at this python, NOT at `uv run`: Jupyter starts,
    # restarts and signals the kernel process itself, and `uv run` would sit
    # between the two as the process it actually controls.  LIB LAYA learned
    # the same thing the hard way (packages/laya/README.md): a kill reached
    # uv and left the real child answering.
    for _s in lab console; do
        if have_sub "$venv/bin/jupyter" "$_s"; then front="$venv/bin/jupyter"; front_sub="$_s"; break; fi
    done
    launcher="tools/jupyter/lab.sh"

else
    # No uv.  The original fallback: a plain venv with pip.
    venv="$HOME/.cache/pop11-skill/jupyter-venv"
    if [ ! -x "$venv/bin/python3" ]; then
        echo "install-kernel: creating venv at $venv"
        python3 -m venv "$venv"
    fi
    "$venv/bin/python3" -c 'import ipykernel' 2>/dev/null || {
        echo "install-kernel: installing ipykernel into the venv"
        "$venv/bin/pip" -q install ipykernel
    }
    py="$venv/bin/python3"
    for _s in lab console; do
        if have_sub "$venv/bin/jupyter" "$_s"; then front="$venv/bin/jupyter"; front_sub="$_s"; break; fi
    done
    if [ -z "$front" ] && [ -z "$POP11_KERNEL_NO_FRONTEND" ]; then
        echo "install-kernel: no jupyter frontend found; installing jupyterlab into the venv"
        "$venv/bin/pip" -q install jupyterlab jupyter-console
        for _s in lab console; do
            if have_sub "$venv/bin/jupyter" "$_s"; then front="$venv/bin/jupyter"; front_sub="$_s"; break; fi
        done
    fi
fi
echo "install-kernel: kernel python: $py"

# ---- write the kernelspec --------------------------------------------------
case "$(uname -s)" in
    Darwin) kdir="$HOME/Library/Jupyter/kernels/pop11" ;;
    *)      kdir="${XDG_DATA_HOME:-$HOME/.local/share}/jupyter/kernels/pop11" ;;
esac
mkdir -p "$kdir"
cat > "$kdir/kernel.json" <<EOF
{
  "argv": ["$py", "$kernel_py", "-f", "{connection_file}"],
  "display_name": "Pop-11",
  "language": "pop11",
  "env": { "POP11_SESSION_BIN": "$popsession" }
}
EOF
echo "install-kernel: kernelspec written to $kdir"

# ---- say what to run next --------------------------------------------------
# The kernelspec lives in the per-user Jupyter data directory, so ANY frontend
# on this machine can see it; it need not be the python the kernel runs under.
nb="examples/notebooks/pop11-live.ipynb"
[ -f "$(cd "$here/../.." && pwd)/$nb" ] || nb=""

echo
if [ -n "$front" ]; then
    echo "Ready.  Open a notebook with:"
    if [ "$front" = "jupyter" ]; then
        echo "    jupyter $front_sub ${nb:+$nb}"
    else
        # Neither venv is put on PATH, so print something runnable rather than
        # a bare `jupyter lab` -- which is exactly what fails for someone who
        # has only this one, and was the original complaint.
        if [ -n "$launcher" ]; then
            echo "    $launcher ${nb:+$nb}"
            echo "  (or in full: $front $front_sub)"
        else
            echo "    $front $front_sub ${nb:+$nb}"
            echo "  (that jupyter is in a venv and not on your PATH)"
        fi
    fi
    echo "and pick the Pop-11 kernel."
else
    echo "The Pop-11 kernel is registered, but this machine has no Jupyter"
    echo "frontend to run it with -- ipykernel is the kernel side only."
    echo "Either install uv (https://docs.astral.sh/uv/) and re-run this"
    echo "script, which sets up both from tools/jupyter/uv.lock, or:"
    echo "    python3 -m pip install jupyterlab      # or: pipx install jupyterlab"
    [ -n "$nb" ] && echo "    jupyter lab $nb"
fi
