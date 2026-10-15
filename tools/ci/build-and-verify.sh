#!/bin/sh
# build-and-verify.sh — CI worker for the pop11-skill tarball, one platform.
# Runs on the current machine; safe to run locally too.
#
#   tools/ci/build-and-verify.sh [outdir]        (default outdir: dist)
#
# Steps:
#   1. engine  — ensure target/pop/basepop11 is CURRENT: download the
#                corepop seed for this platform from GitHub releases
#                (checksum verified), ./configure && make all && make
#                buildclean.  Rebuilt when the engine is absent, when
#                FORCE_ENGINE_REBUILD=1, or when the engine sources have
#                changed since the engine was built (fingerprint, see
#                below).  "Already has one" is not the same as "has a
#                current one", and for two months on riscv64 it was not.
#   1b. selftest — tools/test-libs.sh over $POP11_CI_SUITES (default
#                test_primitives.p + test_fileutils.p) against
#                the engine just built, BEFORE anything is packaged.  The
#                smoke tests below exercise sqlite, MCP and LSP; none of
#                them touches the large-literal or large-closure paths, so
#                an engine that crashes there packaged and shipped green.
#   2. package — tools/release-skill-tarball.sh . <outdir>
#   3. verify  — the tarball contains the engine, wrapper, pop/lib and the
#                full skill (SKILL.md sections + both C shims).
#   4. smoke   — run the real network installer against the local tarball
#                (POP11_SKILL_URL=file://...) in a sandbox $HOME, which
#                unpacks, relocates, builds popcurl+popsqlite and runs a
#                live session; then one in-process sqlite query.
#
# Env: FORCE_ENGINE_REBUILD=1   rebuild the engine even if present
#      POP11_CI_SUITES          suites for the self-test gate (see step 1b)
#
# Any rebuild is a CLEAN rebuild; FORCE_ENGINE_REBUILD only forces the
# decision, it does not change how the build is done.
#      POP11_SEED_BASE_URL      corepop seed source (default: the pinned
#                               corepops release, see `seeds=` below)
#
# No credentials are used or required: everything here is public.
set -e

repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-dist}"
cd "$repo"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)  plat=aarch64-darwin; tarball=pop11-skill-macos-arm64.tar.gz ;;
    Linux/x86_64)  plat=x86_64-linux;   tarball=pop11-skill-linux-x86_64.tar.gz ;;
    Linux/aarch64) plat=aarch64-linux;  tarball=pop11-skill-linux-aarch64.tar.gz ;;
    Linux/riscv64) plat=riscv64-linux;  tarball=pop11-skill-linux-riscv64.tar.gz ;;
    *) echo "ci: unsupported platform $(uname -s)/$(uname -m)" >&2; exit 2 ;;
esac
# Pinned to a corepops tag, not releases/latest: "latest" is one slot and
# two release series compete for it (seeds and skill tarballs), so a skill
# release would silently change which seed a fresh workspace bootstraps
# from -- and a bootstrap seed is exactly the thing that should not float.
# Bump this when a new corepops-YYYY.MM is published.
seeds="${POP11_SEED_BASE_URL:-https://github.com/IoTone/poplog/releases/download/corepops-2026.10}"

# riscv64 Poplog must run with ASLR off (PORTING-RISCV64-LINUX.md);
# that includes popc during the engine build, so re-exec the whole
# script under setarch -R once.
if [ "$(uname -m)" = riscv64 ] && [ -z "$POP11_CI_NOASLR" ]; then
    POP11_CI_NOASLR=1 exec setarch -R sh "$0" "$@"
fi

sha256() {  # portable: sha256sum on Linux, shasum on macOS
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
    else shasum -a 256 "$@"; fi
}

# Everything that can change the engine binary, hashed by CONTENT.
#
# Not mtimes: both ways a platform receives a tree -- a git checkout and
# tools/ci/pack-tree.sh -- rewrite timestamps freely, so a timestamp test
# either rebuilds every run or never rebuilds at all.  A content hash of
# 6 MB of source costs under a second even on the riscv board, which is
# nothing against the two months it would have saved there.
engine_fingerprint() {
    { find pop/src pop/extern -type f \
           \( -name '*.p'  -o -name '*.ph' -o -name '*.s' \
           -o -name '*.c'  -o -name '*.h'  -o -name '*.olb' \) -print \
        | LC_ALL=C sort | tr '\n' '\0' | xargs -0 cat
      cat Makefile.in configure
    } 2>/dev/null | sha256 | awk '{print $1}'
}

# ---- 1. engine ------------------------------------------------------------
fp_file=target/pop/.engine-fingerprint
fp_want="$(engine_fingerprint)"
fp_have="$(cat "$fp_file" 2>/dev/null || echo none)"

rebuild=0
if [ "${FORCE_ENGINE_REBUILD:-0}" = 1 ]; then
    rebuild=1
elif [ ! -x target/pop/basepop11 ]; then
    rebuild=1
elif [ "$fp_want" != "$fp_have" ]; then
    rebuild=1
    echo "ci: engine sources changed since this engine was built"
    echo "ci:   have $fp_have"
    echo "ci:   want $fp_want"
fi

if [ "$rebuild" = 1 ]; then
    echo "ci: building engine for $plat"
    # EVERY rebuild is clean, not just a forced one.  Incremental make over
    # stale popc-compiled objects does not reliably pick up .ph/.s source
    # changes (field-learned twice) -- and those are exactly the changes the
    # fingerprint above detects, so rebuilding incrementally here would spot
    # the staleness and then fail to cure it.  Keep only the corepop seed.
    echo "ci: clearing build products"
    saved=
    if [ -x target/pop/corepop ]; then
        # In the tree, not /tmp: rm -rf below does not reach the repo root,
        # and a shared board's /tmp is somebody else's disk.
        saved="./.ci-corepop.$$"
        mv target/pop/corepop "$saved"
    fi
    rm -rf target stamp_* Makefile poplog
    mkdir -p target/pop
    # if/then, not `[ ... ] && mv`: a false test is a non-zero statement and
    # under set -e that exits the script -- silently, on exactly the fresh
    # workspace where there is no seed to restore.
    if [ -n "$saved" ]; then
        mv "$saved" target/pop/corepop
    fi
    if [ ! -x target/pop/corepop ]; then
        mkdir -p target/pop
        curl -fsSL -o target/pop/corepop "$seeds/corepop-$plat"
        curl -fsSL -o target/pop/SHA256SUMS.seeds "$seeds/SHA256SUMS"
        ( cd target/pop && \
          grep "corepop-$plat\$" SHA256SUMS.seeds | \
          sed "s#corepop-$plat#corepop#" | sha256 -c - )
        rm -f target/pop/SHA256SUMS.seeds
        chmod 755 target/pop/corepop
    fi
    ./configure
    make all
    make buildclean
else
    echo "ci: reusing built engine, sources unchanged ($fp_have)"
fi

# ---- 1b. engine self-test -------------------------------------------------
# Before packaging, not after: an engine that fails here must not become a
# tarball.  The harness supplies the watchdog and reads the SUMMARY line, so
# a hang is a failure rather than a stuck stage.
# POP11_CI_SUITES widens the gate.  Two suites by default, each for a
# class of bug the other cannot see:
#   test_primitives  the hand-written arithmetic, large literals and large
#                    closures -- the paths an engine fails on while every
#                    smoke test still passes (riscv64, two months).
#   test_fileutils   the C struct layouts the engine reads through
#                    _extern.  st_nlink was declared a word wide on arm64,
#                    where it is 32 bits, so file_size answered with
#                    st_blksize and file_mtime with nanoseconds, and
#                    test_zmachine could not load a story file at all.
#                    A field read from a neighbouring offset is still a
#                    plausible integer, so nothing else noticed.
#                    See docs/bugs/aarch64-stat-layout.md.
# All 16 suites are green on x86_64, macOS arm64 and the Pi 5 as of
# 2026-10-14, so the gate could be the whole set -- except that
# test_http_client and test_pcre need their C shims built in the tree
# first (tools/build-popcurl.sh, tools/build-poppcre.sh), and at this
# point in the run only the installer sandbox below builds any.  Build
# them here first and this can become:
#     POP11_CI_SUITES=$(echo tools/tests/test_*.p)
echo "ci: engine self-test"
# shellcheck disable=SC2086  # a deliberate word list of suite paths
sh tools/test-libs.sh \
    ${POP11_CI_SUITES:-tools/tests/test_primitives.p tools/tests/test_fileutils.p}

# Recorded only now.  Fingerprinting a build that has not passed its own
# self-test would mark a broken engine as current and skip rebuilding it.
printf '%s\n' "$fp_want" > "$fp_file"

# ---- 2. package -----------------------------------------------------------
rm -f "$out/$tarball"
tools/release-skill-tarball.sh . "$out"
[ -f "$out/$tarball" ] || { echo "ci: expected $out/$tarball" >&2; exit 1; }

# ---- 3. verify contents ---------------------------------------------------
echo "ci: verifying tarball contents"
list="$(tar -tzf "$out/$tarball")"
for path in target/pop/basepop11 poplog pop/lib skill/SKILL.md \
            skill/install.sh skill/bin/popsession skill/bin/pop11run \
            skill/bin/build-popcurl skill/bin/build-popsqlite \
            skill/lib/popcurl_shim.c skill/lib/popsqlite_shim.c \
            pop/mcp/pop11_mcp.p tools/pop11-mcp \
            pop/lsp/pop11_lsp.p tools/pop11-lsp \
            pop/lib/lib/json.p pop/lib/lib/jsonrpc.p \
            pop/lib/lib/incomplete_code.p pop/lib/lib/swank.p \
            tools/pop11-swank; do
    echo "$list" | grep -q "/$path" || {
        echo "ci: tarball missing $path" >&2; exit 1; }
done
skillmd="$(tar -xzOf "$out/$tarball" "$(echo "$list" | grep '/skill/SKILL.md$')")"
for section in 'Regular expressions' 'SQLite: popsqlite' 'popcurl'; do
    echo "$skillmd" | grep -q "$section" || {
        echo "ci: SKILL.md in tarball missing '$section' section" >&2; exit 1; }
done

# ---- 4. live smoke via the real installer ---------------------------------
echo "ci: install + live smoke in sandbox HOME"
sandbox="$(pwd)/$out/ci-sandbox"
rm -rf "$sandbox"; mkdir -p "$sandbox/tmp"
HOME="$sandbox" TMPDIR="$sandbox/tmp" POP11_SKILL_URL="file://$(pwd)/$out/$tarball" \
    sh tools/install-skill.sh
HOME="$sandbox" TMPDIR="$sandbox/tmp" \
    "$sandbox/.claude/skills/pop11/bin/pop11run" -c "
load '$sandbox/.cache/pop11-skill/popsqlite.p';
vars db = sqlite_open(':memory:');
sqlite_exec(db, 'create table t (x)');
sqlite_run_b(db, 'insert into t values (?)', ['ci-ok']);
npr('ci sqlite smoke: ' sys_>< sqlite_query(db, 'select x from t')(1)(1));
" | grep -q 'ci sqlite smoke: ci-ok' || {
    echo "ci: sqlite smoke failed" >&2; exit 1; }

# ---- 5. MCP server smoke over the real protocol ---------------------------
echo "ci: MCP protocol smoke against the installed tarball"
prefix="$sandbox/.local/share/pop11-skill"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pop11_eval","arguments":{"code":"npr(19 + 23);"}}}' \
  | HOME="$sandbox" TMPDIR="$sandbox/tmp" "$prefix/tools/pop11-mcp" \
  | grep -q '"text":"42' || {
    echo "ci: MCP smoke failed" >&2; exit 1; }

# ---- 6. LSP server smoke over the real protocol ---------------------------
echo "ci: LSP protocol smoke against the installed tarball"
lspreq='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
printf 'Content-Length: %s\r\n\r\n%s' "${#lspreq}" "$lspreq" \
  | HOME="$sandbox" TMPDIR="$sandbox/tmp" "$prefix/tools/pop11-lsp" \
  | grep -q '"name":"pop11-lsp"' || {
    echo "ci: LSP smoke failed" >&2; exit 1; }
rm -rf "$sandbox"

echo "ci: OK $out/$tarball"

# Record the sizes.  Only appends for the platform just built; run it on
# each host, or once at the end over a dist/ holding every tarball.
if [ "${POP11_CI_SIZES:-1}" = 1 ]; then
    DIST="$repo/$out" sh tools/release-sizes.sh --print
fi
