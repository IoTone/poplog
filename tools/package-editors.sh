#!/bin/sh
# package-editors.sh — build the editor-extension release artifacts.
#
#   tools/package-editors.sh [outdir]      (default outdir: dist)
#
# Produces (versions read from each extension's manifest):
#   pop11-vscode-<v>.vsix    VS Code: "Extensions: Install from VSIX",
#                            or `code --install-extension <file>`
#   pop11-zed-<v>.tar.gz     Zed: unpack, then `zed: install dev extension`
#                            pointing at the unpacked pop11-zed/ directory
#   pop11-emacs-<v>.tar.gz   Emacs: unpack, then add the directory to
#                            load-path and (require 'inferior-pop11)
#
# Platform-neutral (pure config + grammars): build once, attach to the
# GitHub releases alongside the per-platform skill tarballs.
#
# Needs node/npx for vsce.  VSCE_VERSION is pinned because current @vscode/vsce
# calls node's styleText with two formats at once (['bgGreen','black']), which
# only became legal in node 22 -- on node 20 it dies with ERR_INVALID_ARG_VALUE
# before packaging anything.  Override if you are on a newer node:
#
#     VSCE_VERSION=latest tools/package-editors.sh
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-dist}"
cd "$repo"
mkdir -p "$out"

: "${VSCE_VERSION:=2.32.0}"

vsv="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' editors/vscode/package.json | head -1)"
( cd editors/vscode && \
  npx --yes "@vscode/vsce@$VSCE_VERSION" package \
      --out "$repo/$out/pop11-vscode-$vsv.vsix" ) >/dev/null
echo "packaged: $out/pop11-vscode-$vsv.vsix"

# `tar -s` is BSD (macOS); GNU tar spells the same thing --transform.  The
# script used only the BSD form, so it could never have run on Linux.
if tar --version 2>/dev/null | grep -qi gnu; then
    xform() { echo "--transform=s/^$1/$2/"; }
else
    xform() { echo "-s/^$1/$2/"; }
fi

zedv="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' editors/zed/extension.toml | head -1)"
tar -C editors "$(xform zed pop11-zed)" -czf "$out/pop11-zed-$zedv.tar.gz" zed
echo "packaged: $out/pop11-zed-$zedv.tar.gz"

# Elisp keeps its version in the file header, not a manifest.
emv="$(sed -n 's/^;; Version: *\(.*\)$/\1/p' editors/emacs/pop11-mode.el | head -1)"
tar -C editors "$(xform emacs pop11-emacs)" -czf "$out/pop11-emacs-$emv.tar.gz" emacs
echo "packaged: $out/pop11-emacs-$emv.tar.gz"
