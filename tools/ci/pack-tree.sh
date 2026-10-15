#!/bin/sh
# pack-tree.sh — the source tree a CI platform needs, and nothing else.
#
#   tools/ci/pack-tree.sh [outfile]      (default: poplog-src.tar.gz; - = stdout)
#
# TRACKED FILES ONLY, which is a correctness requirement and not tidiness:
# stamp_*, Makefile, ./poplog and target/ are gitignored build products, and
# shipping this machine's copies makes the far side's make(1) think the
# directory-setup rules have already run.  `git ls-files` also carries local
# edits, so an uncommitted fix can be tested on a board before it lands.
#
# What a build node does NOT get: .git.  61 MB of history on disk for a 15
# MiB pack, to build a tree that never reads it -- and, worse, a checkout on
# the node means every node needs a credential for the remote.  The tarball
# needs none.
#
# Two files go in beside the sources:
#   .ci-manifest  the path list, so the far side can tell what a later tree
#                 has DELETED.  Extraction is additive: without this, a
#                 source file removed from the repo lives on in a reused
#                 workspace, and a stale pop/lib/*.p is still found by
#                 `uses` at runtime.  That is this project's oldest bug
#                 shape; see unpack-tree.sh.
#   .ci-commit    the commit packed, because the far side has no git to ask
#                 and a release-sizes row reading "unknown" is a row that
#                 cannot be traced to a build.
set -e

repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-poplog-src.tar.gz}"
cd "$repo"

# The two metadata files are written into the tree and removed again: one
# flat file list keeps the archive simple.  Interleaving `-C` with `-T -`
# does not work -- BSD tar applies the chdir before it reads the list, and
# then cannot stat a single source file.
trap 'rm -f .ci-manifest .ci-commit' EXIT HUP INT TERM

git ls-files > .ci-manifest
git rev-parse --short HEAD > .ci-commit 2>/dev/null || echo unknown > .ci-commit

pack() {
    { git ls-files -z; printf '.ci-manifest\0.ci-commit\0'; } | \
        tar --null -T - -czf "$1"
}

if [ "$out" = - ]; then
    pack -
else
    pack "$out"
    echo "pack-tree: $out  ($(wc -l < .ci-manifest | tr -d ' ') files, \
commit $(cat .ci-commit), \
$(wc -c < "$out" | awk '{printf "%.1f MB", $1/1048576}'))"
fi
