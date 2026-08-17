#!/bin/sh
# build-and-verify.sh — CI worker for the pop11-skill tarball, one platform.
# Runs on the current machine; safe to run locally too.
#
#   tools/ci/build-and-verify.sh [outdir]        (default outdir: dist)
#
# Steps:
#   1. engine  — ensure target/pop/basepop11 exists: download the corepop
#                seed for this platform from GitHub releases (checksum
#                verified), ./configure && make all && make buildclean.
#                Skipped when a built engine is already in the workspace
#                unless FORCE_ENGINE_REBUILD=1.
#   2. package — tools/release-skill-tarball.sh . <outdir>
#   3. verify  — the tarball contains the engine, wrapper, pop/lib and the
#                full skill (SKILL.md sections + both C shims).
#   4. smoke   — run the real network installer against the local tarball
#                (POP11_SKILL_URL=file://...) in a sandbox $HOME, which
#                unpacks, relocates, builds popcurl+popsqlite and runs a
#                live session; then one in-process sqlite query.
#
# Env: FORCE_ENGINE_REBUILD=1   rebuild the engine even if present
#      POP11_SEED_BASE_URL      corepop seed source (default: this repo's
#                               latest GitHub release)
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
seeds="${POP11_SEED_BASE_URL:-https://github.com/IoTone/poplog/releases/latest/download}"

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

# ---- 1. engine ------------------------------------------------------------
if [ "${FORCE_ENGINE_REBUILD:-0}" = 1 ] || [ ! -x target/pop/basepop11 ]; then
    echo "ci: building engine for $plat"
    if [ "${FORCE_ENGINE_REBUILD:-0}" = 1 ]; then
        # A forced rebuild must be CLEAN: incremental make over stale
        # popc-compiled objects does not reliably pick up .ph/.s source
        # changes (field-learned twice). Keep only the corepop seed.
        echo "ci: forced rebuild — clearing build products"
        if [ -x target/pop/corepop ]; then
            mv target/pop/corepop /tmp/ci-corepop.$$
        fi
        rm -rf target stamp_* Makefile poplog
        mkdir -p target/pop
        [ -f /tmp/ci-corepop.$$ ] && mv /tmp/ci-corepop.$$ target/pop/corepop
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
    echo "ci: reusing built engine (FORCE_ENGINE_REBUILD=1 to rebuild)"
fi

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
            pop/lib/lib/json.p; do
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
