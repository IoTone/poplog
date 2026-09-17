#!/bin/sh
# snapshot-build.sh -- archive a built Poplog tree so it cannot be lost.
#
#   tools/snapshot-build.sh <platform> <good|broken> [--no-upload]
#
# Tars target/pop, target/psv, target/obj and the stamp_* files, writes a
# sha256 and a manifest.json recording what was built and on what, and
# uploads all three to the public, versioned bucket
#
#   s3://poplog-builds/builds/<platform>/<host>-<platform>-<state>-<date>.tgz
#
# Motivation: on 2026-09-16 a rebuild destroyed the only working riscv64
# engine (the link rule deletes basepop11 before relinking, and no rebuild
# since has produced a working one).  A built tree costs tens of minutes to
# an hour on a slow board and ~8 MB to keep.  Run this after every green
# validate-*.sh.  Needs the aws cli and credentials for the upload step;
# --no-upload just produces the files, for boxes without either.
set -eu
plat="${1:?usage: snapshot-build.sh <platform> <good|broken> [--no-upload]}"
state="${2:?usage: snapshot-build.sh <platform> <good|broken> [--no-upload]}"
upload=1; [ "${3:-}" = --no-upload ] && upload=0
cd "$(dirname "$0")/.."
host="$(hostname -s)"; date="$(date +%Y-%m-%d)"
f="${host}-${plat}-${state}-${date}.tgz"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }
tar czf "/tmp/$f" target/pop target/psv target/obj stamp_* 2>/dev/null
( cd /tmp && sha "$f" > "$f.sha256" )
gitsha="$(git rev-parse --short HEAD 2>/dev/null || echo "not a git checkout")"
glibc="$(ldd --version 2>/dev/null | head -1 | sed 's/.*) //' || echo n/a)"
cat > "/tmp/$f.manifest.json" <<EOF
{"platform":"$plat","host":"$host","state":"$state","date":"$date",
 "sha256":"$(cut -d' ' -f1 "/tmp/$f.sha256")","bytes":$(wc -c < "/tmp/$f" | tr -d ' '),
 "kernel":"$(uname -sr)","glibc":"$glibc","cc":"$(cc --version 2>/dev/null | head -1)",
 "git":"$gitsha","contents":"target/pop target/psv target/obj stamp_*"}
EOF
echo "wrote /tmp/$f  ($(cut -c1-16 "/tmp/$f.sha256"))"
[ $upload = 1 ] || exit 0
b="s3://poplog-builds/builds/$plat"
for x in "$f" "$f.sha256" "$f.manifest.json"; do aws s3 cp "/tmp/$x" "$b/$x" --no-progress; done
echo "https://poplog-builds.s3.us-west-1.amazonaws.com/builds/$plat/$f"
