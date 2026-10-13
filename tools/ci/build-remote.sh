#!/bin/sh
# build-remote.sh — run the CI build for one platform on a remote machine
# over plain ssh, driven from the Linux builder.  No Jenkins agent, no JVM
# and no swarm client is needed on the target board: if you can ssh to it
# and it has cc/make/curl/tar, it can be a CI platform.
#
#   tools/ci/build-remote.sh <ssh-host> [outdir] [remote-dir]
#
# <ssh-host> is anything ssh accepts — an ~/.ssh/config alias ("raspi5"),
# or user@host.  In Jenkins it comes from a job parameter or credential,
# never from this repo (see the Jenkinsfile header).  It may carry the
# remote dir as a "host:dir" suffix, so a single parameter can aim a
# short-on-disk board at an existing tree: "riscv-cloud:poplog".
# [outdir]     local directory to collect the tarball into (default: dist)
# [remote-dir] build tree on the remote, relative to its $HOME
#              (default: poplog-ci).  Pointing this at a tree that already
#              has target/pop/basepop11 reuses the engine (much faster, and
#              it matters on boards with little free disk).
#
# Steps:
#   1. probe   — check ssh works and the remote has the build prerequisites
#   2. sync    — copy this working tree's *tracked* files (git ls-files,
#                so local edits go too) through tar over the ssh channel.
#                Tracked-only matters: stamp_*, Makefile, ./poplog and
#                target/ are gitignored build products, and shipping this
#                machine's copies makes the remote make(1) skip its
#                directory-setup rules and fail.
#   3. build   — tools/ci/build-and-verify.sh on the remote, which fetches
#                that platform's corepop seed, builds, packages the skill
#                tarball and runs the installer smoke test.
#   4. collect — bring the tarball back to <outdir> so the caller can
#                archive/publish it exactly like a local build.
#
# Env: FORCE_ENGINE_REBUILD=1   rebuild the remote engine even if present
#      POP11_SEED_BASE_URL      corepop seed source (passed through)
#      SSH_OPTS                 extra ssh options, in -o form so scp takes
#                               them too (e.g. '-o BatchMode=yes').  On a
#                               board with a shaky link, '-o
#                               ServerAliveInterval=15' is worth adding: a
#                               build holds one channel open for many
#                               minutes.
#
# Exit: 0 built and collected      2 remote is unusable (missing tool/header,
#       3 the ssh link failed        unsupported platform, sync/copy trouble)
#       other  the remote build's own status, passed through
set -e

host="${1:?usage: build-remote.sh <ssh-host> [outdir] [remote-dir]}"
out="${2:-dist}"
rdir="${3:-}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

# accept the scp-ish "host:dir" spelling so one job parameter carries both
case "$host" in
    *:*) : "${rdir:=${host##*:}}"; host="${host%:*}" ;;
esac
: "${rdir:=poplog-ci}"

# shellcheck disable=SC2086  # SSH_OPTS is a deliberate word list
ssh_() { ssh $SSH_OPTS "$host" "$@"; }

# ssh(1) exits 255 for its own failures -- connect, auth, or a link that
# drops mid-session -- which is otherwise indistinguishable from the remote
# command exiting non-zero.  Without this a flaky network reports as
# "$host lacks cc" and sends you off debugging the wrong machine.
die_if_transport() {
    [ "$1" = 255 ] || return 0
    echo "build-remote: lost the ssh connection to $host" >&2
    echo "  (link trouble, not a build failure -- check the board's network;" >&2
    echo "   SSH_OPTS='-o ServerAliveInterval=15' may ride out brief drops)" >&2
    exit 3
}

# ---- 1. probe -------------------------------------------------------------
echo "== $host: probing =="
uname="$(ssh_ 'uname -s; uname -m' | tr '\n' '/')" || {
    echo "build-remote: cannot ssh to $host" >&2; exit 2; }
uname="${uname%/}"
arch="${uname#*/}"
echo "build-remote: $host is $uname"

# The tool and header checks live in tools/ci/probe-prereqs.sh, which runs
# on the remote after the sync (step 2b) -- one list of prerequisites for
# both CI routes rather than a copy here that drifts from it.

# same platform table as build-and-verify.sh, resolved before the build so
# a typo'd host fails in seconds rather than an hour in
case "$uname" in
    Linux/aarch64)  tarball=pop11-skill-linux-aarch64.tar.gz ;;
    Linux/x86_64)   tarball=pop11-skill-linux-x86_64.tar.gz ;;
    Linux/riscv64)  tarball=pop11-skill-linux-riscv64.tar.gz ;;
    Darwin/arm64)   tarball=pop11-skill-macos-arm64.tar.gz ;;
    *) echo "build-remote: unsupported remote platform $uname" >&2; exit 2 ;;
esac

# riscv64 restores a fixed-address saved image: it must run with ASLR off
run_prefix=''
[ "$arch" = riscv64 ] && run_prefix='setarch -R '

# ---- 2. sync tracked files ------------------------------------------------
# pack-tree.sh/unpack-tree.sh, the same pair the Jenkins node route uses
# over the agent channel, so both routes deliver a byte-identical tree.
# Streamed rather than scp'd: one ssh channel, nothing left in /tmp.
echo "== $host: syncing tree -> ~/$rdir =="
ssh_ "mkdir -p '$rdir'"
sh tools/ci/pack-tree.sh - | ssh_ "cat > '$rdir/poplog-src.tar.gz'" || {
    st=$?; die_if_transport "$st"
    echo "build-remote: sending the tree to $host failed" >&2; exit 2; }
# The unpacker rides inside the archive, so pull it out first and then let
# it do the real extraction: it also prunes sources this tree no longer has,
# which plain `tar -xzf` into a reused directory would silently keep.
ssh_ "cd '$rdir' && tar -xzf poplog-src.tar.gz tools/ci/unpack-tree.sh && \
      sh tools/ci/unpack-tree.sh poplog-src.tar.gz" || {
    st=$?; die_if_transport "$st"
    echo "build-remote: unpacking the tree on $host failed" >&2; exit 2; }

# ---- 2b. prerequisites on the remote -------------------------------------
# After the sync, because the script it runs arrived with it.  Seconds, and
# it saves an hour: the engine builds happily without <sqlite3.h> and then
# step 4 fails when the installer compiles the popsqlite shim.
echo "== $host: prerequisites =="
ssh_ "cd '$rdir' && sh tools/ci/probe-prereqs.sh" || { st=$?; die_if_transport "$st"
    echo "build-remote: $host is missing build prerequisites (see above)" >&2
    exit 2; }

# ---- 3. build on the remote ----------------------------------------------
echo "== $host: build + verify =="
ssh_ "cd '$rdir' && \
      FORCE_ENGINE_REBUILD='${FORCE_ENGINE_REBUILD:-0}' \
      ${POP11_SEED_BASE_URL:+POP11_SEED_BASE_URL='$POP11_SEED_BASE_URL'} \
      ${run_prefix}sh tools/ci/build-and-verify.sh dist" || {
    st=$?; die_if_transport "$st"
    echo "build-remote: the build failed on $host (status $st)" >&2; exit "$st"; }

# ---- 4. collect -----------------------------------------------------------
echo "== $host: collecting $tarball =="
mkdir -p "$out"
scp $SSH_OPTS -q "$host:$rdir/dist/$tarball" "$out/$tarball" || {
    st=$?; die_if_transport "$st"
    echo "build-remote: could not fetch $tarball from $host" >&2; exit 2; }
ls -l "$out/$tarball"

echo "build-remote: OK $host -> $out/$tarball"
