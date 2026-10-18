#!/bin/sh
# lab.sh — open a Pop-11 notebook, setting up whatever is missing first.
#
#   tools/jupyter/lab.sh [notebook-or-directory] [jupyter args...]
#   tools/jupyter/lab.sh --console          a terminal REPL, no browser
#   tools/jupyter/lab.sh --execute nb.ipynb run it headlessly, in place
#
# With no arguments it opens examples/notebooks/ in JupyterLab.  Paths are
# taken relative to where you ran it, not to this directory.
#
# This exists so that nothing has to be on your PATH.  The environment is
# the locked uv project beside this script (pyproject.toml, uv.lock), and
# install-kernel.sh registers the kernel; both are idempotent and cheap, so
# this runs them every time rather than asking you to remember whether you
# have.  Needs uv (https://docs.astral.sh/uv/); without it, run
# install-kernel.sh, which has a pip fallback, and use the command it prints.
set -e

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

command -v uv >/dev/null 2>&1 || {
    echo "lab.sh: needs uv (https://docs.astral.sh/uv/)" >&2
    echo "  without it: tools/jupyter/install-kernel.sh, then run what it prints" >&2
    exit 2
}

sub=lab
case "$1" in
    --console) sub=console; shift ;;
    --execute) sub=execute; shift ;;
esac

# --frozen: use uv.lock as committed.  A resolution that drifts here is a
# different Jupyter from the one the committed notebook outputs were made
# with, which is the sort of difference nobody notices until a diff is
# unexplainable.
uv sync -q --frozen --project "$here" >/dev/null

# The kernel has to be registered before a frontend can list it, and the
# kernelspec records an absolute path to this venv's python -- so it is
# rewritten on every run, keeping it right across a moved checkout or a
# recreated venv.  Its stdout is the "what to run next" advice, which is
# this script; errors still come through on stderr.
"$here/install-kernel.sh" >/dev/null

jup="$here/.venv/bin/jupyter"
case $sub in
    lab)
        # Open on the notebooks directory rather than the repo root, which is
        # a wall of C sources.  Keyed on the first argument not looking like a
        # path, NOT on `[ $# -gt 0 ]`: a caller passing only jupyter flags
        # (`--no-browser --port 8899`) still gave no path, and testing the
        # count alone silently served the repo root.  As a root_dir rather
        # than a positional so an explicit path still wins, and left alone
        # entirely if the caller set a root of their own.
        case "${1:-}" in
            ''|-*)
                case " $* " in
                    *" --ServerApp.root_dir"*|*" --notebook-dir"*) ;;
                    *) set -- --ServerApp.root_dir="$repo/examples/notebooks" "$@" ;;
                esac
                ;;
        esac
        exec "$jup" lab "$@"
        ;;
    console) exec "$jup" console --kernel pop11 "$@" ;;
    execute) exec "$jup" execute --kernel_name=pop11 "$@" ;;
esac
