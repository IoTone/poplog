#!/bin/sh
# release-skill-tarball.sh — package a built Poplog tree + the pop11 Claude
# skill as a relocatable binary tarball for GitHub releases.
#
#   tools/release-skill-tarball.sh /path/to/built/poplog-tree [outdir]
#
# Produces:  <outdir>/pop11-skill-<os>-<arch>.tar.gz
# Layout inside (extracted with --strip-components=1 by install-skill.sh):
#   pop11-skill/
#     poplog            env wrapper (poplogroot rewritten at install time)
#     target/pop/       basepop11 + saved images
#     pop/lib/          autoloadable + system libraries
#     pop/mcp/          the MCP server (pop11_mcp.p, runs on lib json)
#     tools/pop11-mcp   MCP server launcher (register with an MCP client)
#     skill/            the Claude skill (SKILL.md, bin/, lib/, install.sh)
#
# Runtime relocatability: the wrapper derives every pop* env var from
# $poplogroot, and neither basepop11 nor the libraries embed build paths, so
# rewriting the wrapper's poplogroot= line is the only fix-up needed
# (verified: subset copied to a fresh path runs, autoload included).
set -e

src="${1:?usage: release-skill-tarball.sh /path/to/built/tree [outdir]}"
out="${2:-.}"
repo="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$src/target/pop/basepop11" ] || {
    echo "release-skill-tarball: $src has no target/pop/basepop11" >&2; exit 2; }

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "release-skill-tarball: unsupported OS $(uname -s)" >&2; exit 2 ;;
esac
arch="$(uname -m)"
name="pop11-skill-$os-$arch"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name/target" "$stage/$name/pop"

cp "$src/poplog" "$stage/$name/poplog"
# One binary only: pop11/clisp/prolog/pml/ved are hard links to basepop11 in
# a built tree — cp -R would expand them into 7 full copies (31 MB of
# duplication). The skill invokes basepop11 directly; nothing else is needed
# at runtime (corepop/.map/.stb/popc,poplibr,poplink.psv are build tooling).
mkdir -p "$stage/$name/target/pop"
cp "$src/target/pop/basepop11" "$stage/$name/target/pop/basepop11"
cp -R "$src/pop/lib" "$stage/$name/pop/lib"
cp -R "$repo/.claude/skills/pop11" "$stage/$name/skill"
# The MCP server ships too (its launcher falls back to $root/pop/mcp when
# not run from a checkout).  Sources live in the repo, not the built tree.
mkdir -p "$stage/$name/pop/mcp" "$stage/$name/pop/lsp" "$stage/$name/tools"
cp "$repo/pop/mcp/pop11_mcp.p" "$stage/$name/pop/mcp/pop11_mcp.p"
cp "$repo/tools/pop11-mcp" "$stage/$name/tools/pop11-mcp"
# ... and the LSP server (same launcher fallback scheme)
cp "$repo/pop/lsp/pop11_lsp.p" "$stage/$name/pop/lsp/pop11_lsp.p"
cp "$repo/tools/pop11-lsp" "$stage/$name/tools/pop11-lsp"
# The freely-licensed story files, so LIB ZMACHINE has something to play
# out of the box ($usepop/examples/games/cave.z3).
mkdir -p "$stage/$name/examples/games"
cp "$repo"/examples/games/*.z3 "$repo"/examples/games/*.z5 \
   "$repo/examples/games/README.md" "$stage/$name/examples/games/"

mkdir -p "$out"
tar -C "$stage" -czf "$out/$name.tar.gz" "$name"
ls -lh "$out/$name.tar.gz"
echo "upload with: gh release upload <tag> $out/$name.tar.gz"
