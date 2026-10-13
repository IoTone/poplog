#!/bin/sh
# probe-prereqs.sh — can this machine run the CI build at all?
#
#   tools/ci/probe-prereqs.sh
#
# An hour into a from-seed build on a small board is a bad moment to learn
# that <sqlite3.h> is missing: the engine builds fine without it, and then
# step 4 of build-and-verify.sh fails when the installer tries to compile
# the popsqlite shim.  This checks, in seconds, everything the build and
# the smoke tests need, and names the package to install when something is
# absent.
#
# Used by the native Jenkins stages (the builder, the Pi) and by
# build-remote.sh on the far side of the ssh link, so both paths demand the
# same things of a platform.  Safe to run by hand on a new board.
#
# Exit: 0 usable   2 something required is missing (every miss is reported,
#                    not just the first — one trip to apt, not four)
set -e

missing=0
note() { echo "probe: $*" >&2; missing=1; }

echo "probe: $(uname -s)/$(uname -m), $(hostname 2>/dev/null || echo '?')"

# ---- platform -------------------------------------------------------------
# Same table as build-and-verify.sh.  A platform with no corepop seed has
# nothing to bootstrap from, so there is no point going further.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64|Linux/x86_64|Linux/aarch64|Linux/riscv64) ;;
    *) note "unsupported platform $(uname -s)/$(uname -m)" ;;
esac

# ---- tools ----------------------------------------------------------------
# git is here because a Jenkins node with its own workspace checks the tree
# out itself; the ssh path gets the tree by tar and does not need it, but
# demanding it everywhere keeps one list rather than two.
for tool in cc make curl tar git; do
    command -v "$tool" >/dev/null 2>&1 || note "no $tool on PATH"
done

# riscv64 restores a saved image at a fixed address: the whole build, popc
# included, has to run with ASLR off.
if [ "$(uname -m)" = riscv64 ]; then
    command -v setarch >/dev/null 2>&1 || \
        note "no setarch (riscv64 needs 'setarch -R'; Debian: util-linux)"
fi

# ---- headers --------------------------------------------------------------
# The installer smoke test builds both C shims, and the engine links
# against ncurses; all three are dev packages that a minimal board image
# will not have.
if command -v cc >/dev/null 2>&1; then
    for hdr in curl/curl.h sqlite3.h ncurses.h; do
        printf '#include <%s>\nint main(void){return 0;}\n' "$hdr" | \
            cc -fsyntax-only -x c - 2>/dev/null || note "no <$hdr>"
    done
fi

if [ "$missing" = 1 ]; then
    case "$(uname -s)" in
        Linux) echo "probe: Debian/Ubuntu: apt install build-essential git curl \\
         libcurl4-openssl-dev libsqlite3-dev libncurses-dev" >&2 ;;
        Darwin) echo "probe: macOS: xcode-select --install" >&2 ;;
    esac
    exit 2
fi

# ---- disk -----------------------------------------------------------------
# Advisory, not fatal: a from-seed build plus the tarball and the installer
# sandbox wants a few GB, and a board that runs out mid-make leaves a
# half-built tree that then fails confusingly on the next run.  df -P is
# the portable spelling (one line per filesystem, 1K blocks).
avail="$(df -P . 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
case "$avail" in
    ''|*[!0-9]*) ;;                 # unreadable df output: say nothing
    *)
        echo "probe: ${avail}G free here"
        if [ "$avail" -lt 4 ]; then
            echo "probe: warning: under 4G free; a from-seed build may not fit" >&2
        fi
        ;;
esac

echo "probe: OK"
