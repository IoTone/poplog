#!/bin/sh
# install-kernel.sh — register the Pop-11 Jupyter kernel.
#
#   tools/jupyter/install-kernel.sh
#
# Uses the running python3 if it already has ipykernel; otherwise creates
# a small dedicated venv at ~/.cache/pop11-skill/jupyter-venv (alongside
# the skill's other machine state) and installs ipykernel there.  Then
# writes the kernelspec so `jupyter lab` / `jupyter console` list
# "Pop-11".
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
#   POP11_KERNEL_PYTHON python to run the kernel with (skips venv logic)
#   POP11_KERNEL_NO_FRONTEND
#                       non-empty: register the kernel and install no
#                       frontend, even when this script owns the venv
set -e

here="$(cd "$(dirname "$0")" && pwd)"
kernel_py="$here/pop11_kernel.py"
popsession="${POP11_SESSION_BIN:-$HOME/.claude/skills/pop11/bin/popsession}"

[ -x "$popsession" ] || {
    echo "install-kernel: popsession not found at $popsession" >&2
    echo "  (install the pop11 skill first, or set POP11_SESSION_BIN)" >&2
    exit 2
}

# ---- pick a python with ipykernel -----------------------------------------
py="$POP11_KERNEL_PYTHON"
if [ -z "$py" ] && python3 -c 'import ipykernel' 2>/dev/null; then
    py="$(command -v python3)"
fi
venv=""
if [ -z "$py" ]; then
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

# ---- resolve a frontend ----------------------------------------------------
# The kernelspec lives in the per-user Jupyter data directory, so ANY
# frontend on this machine can see it -- it does not have to be the python
# the kernel runs under.  Prefer one already on PATH and touch nothing;
# `jupyter <sub> --version` exits 0 when the subcommand exists and 1 when
# it does not, which is the check, because the jupyter_core launcher is
# present either way (ipykernel pulls it in) and so `command -v jupyter`
# proves nothing.
have_sub() {           # have_sub <jupyter-binary> <subcommand>
    "$1" "$2" --version >/dev/null 2>&1
}

front=""; front_sub=""
if command -v jupyter >/dev/null 2>&1; then
    for sub in lab notebook console; do
        if have_sub jupyter "$sub"; then front="jupyter"; front_sub="$sub"; break; fi
    done
fi

# Nothing usable on PATH.  If this script created the venv, it owns it and
# can finish the job; if the python came from the user (POP11_KERNEL_PYTHON,
# or their own python3 that already had ipykernel) then installing into it
# is not this script's business -- say what is missing instead.
if [ -z "$front" ] && [ -n "$venv" ] && [ -z "$POP11_KERNEL_NO_FRONTEND" ]; then
    for sub in lab console; do
        if have_sub "$venv/bin/jupyter" "$sub"; then front="$venv/bin/jupyter"; front_sub="$sub"; break; fi
    done
    if [ -z "$front" ]; then
        echo "install-kernel: no jupyter frontend found; installing jupyterlab into the venv"
        "$venv/bin/pip" -q install jupyterlab jupyter-console
        for sub in lab console; do
            if have_sub "$venv/bin/jupyter" "$sub"; then front="$venv/bin/jupyter"; front_sub="$sub"; break; fi
        done
    fi
fi

nb="$(cd "$here/../.." && pwd)/examples/notebooks/pop11-live.ipynb"
[ -f "$nb" ] || nb=""

echo
if [ -n "$front" ]; then
    # The venv is deliberately not put on PATH, so print it in full: a bare
    # `jupyter lab` is exactly what fails for someone who only has this one.
    echo "Ready.  Open a notebook with:"
    echo "    $front $front_sub ${nb:+$nb}"
    [ "$front" = "jupyter" ] || echo "  (that jupyter lives in the venv and is not on your PATH)"
    echo "and pick the Pop-11 kernel.  Or: $front console --kernel pop11"
else
    echo "The Pop-11 kernel is registered, but this machine has no Jupyter"
    echo "frontend to run it with -- ipykernel is the kernel side only."
    echo "Install one, then pick Pop-11:"
    echo "    python3 -m pip install jupyterlab      # or: pipx install jupyterlab"
    [ -n "$nb" ] && echo "    jupyter lab $nb"
fi
