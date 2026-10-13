#!/bin/sh
# unpack-tree.sh — lay a packed source tree into a reused CI workspace.
#
#   tools/ci/unpack-tree.sh [tarball]    (default: poplog-src.tar.gz)
#
# Run from the workspace root.  The tarball keeps its sources; target/,
# stamp_*, Makefile and ./poplog are left alone, which is the whole point of
# a persistent workspace: the engine is reused instead of rebuilt from a
# corepop seed.
#
# The part that is not just `tar -xzf`: tar is ADDITIVE.  A source file
# deleted from the repo survives in a reused workspace forever, and a stale
# pop/lib/*.p is still found by `uses` at runtime -- so the build goes green
# while testing a file that no longer exists.  This repo has been bitten by
# that shape of bug more than once (docs/bugs, and the Pi's own stale
# aarith.s).  `checkout scm` got deletions right for free; a tarball has to
# be told.
#
# So: the previous build's manifest is kept as .ci-manifest.prev, and any
# path it listed that the new manifest does not is removed.  Exact, no
# whitelist of build products to keep in sync, and a no-op on a fresh
# workspace.
set -e

tar="${1:-poplog-src.tar.gz}"
[ -f "$tar" ] || { echo "unpack-tree: no $tar here" >&2; exit 2; }

# Before extraction, or the incoming .ci-manifest overwrites the record of
# what the last build had.
if [ -f .ci-manifest ]; then mv -f .ci-manifest .ci-manifest.prev; fi

tar -xzf "$tar"
[ -f .ci-manifest ] || { echo "unpack-tree: $tar has no .ci-manifest" >&2; exit 2; }

echo "unpack-tree: $(wc -l < .ci-manifest | tr -d ' ') files, commit $(cat .ci-commit 2>/dev/null || echo '?')"

# Prune what the tree no longer has.  Plain text both sides, sorted, so
# comm(1) does the work; -2 -3 leaves lines only in the previous manifest.
if [ -f .ci-manifest.prev ]; then
    sort .ci-manifest.prev > .ci-prev.sorted
    sort .ci-manifest      > .ci-new.sorted
    gone="$(comm -23 .ci-prev.sorted .ci-new.sorted)"
    rm -f .ci-prev.sorted .ci-new.sorted
    if [ -n "$gone" ]; then
        echo "unpack-tree: removing $(printf '%s\n' "$gone" | wc -l | tr -d ' ') file(s) \
dropped from the tree since the last build"
        printf '%s\n' "$gone" | while IFS= read -r p; do
            [ -n "$p" ] || continue
            rm -f "./$p"
            echo "  - $p"
        done
        # Emptied directories are deliberately LEFT.  make's
        # stamp_dirs_and_symlinks rule creates pop/ref/doc_index and
        # friends once and is then satisfied by its stamp file, so pruning
        # an empty directory here breaks the next incremental build in a
        # reused workspace.
    fi
    rm -f .ci-manifest.prev
fi
