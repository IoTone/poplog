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
# Needs node/npx for vsce.
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-dist}"
cd "$repo"
mkdir -p "$out"

vsv="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' editors/vscode/package.json | head -1)"
( cd editors/vscode && \
  npx --yes @vscode/vsce package --out "$repo/$out/pop11-vscode-$vsv.vsix" ) >/dev/null
echo "packaged: $out/pop11-vscode-$vsv.vsix"

zedv="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' editors/zed/extension.toml | head -1)"
tar -C editors -s '/^zed/pop11-zed/' -czf "$out/pop11-zed-$zedv.tar.gz" zed
echo "packaged: $out/pop11-zed-$zedv.tar.gz"

# Elisp keeps its version in the file header, not a manifest.
emv="$(sed -n 's/^;; Version: *\(.*\)$/\1/p' editors/emacs/pop11-mode.el | head -1)"
tar -C editors -s '/^emacs/pop11-emacs/' -czf "$out/pop11-emacs-$emv.tar.gz" emacs
echo "packaged: $out/pop11-emacs-$emv.tar.gz"
