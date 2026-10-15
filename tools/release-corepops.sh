#!/usr/bin/env bash
# Assemble the corepop release assets from nix/seeds/ into a dist
# directory: the seed binaries, SHA256SUMS, manifest.json, and
# RELEASE_NOTES.md.  Run locally or from the corepops-release workflow:
#
#   tools/release-corepops.sh [outdir]     (default: dist/corepops)
#
# The seeds are the hand-blessed bootstrap binaries ("compiler-compiler"
# seeds, PORTING-POPLOG.md part 6); this script only packages and
# checksums them -- it never rebuilds them.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$repo_root/dist/corepops"}
seeds="$repo_root/nix/seeds"

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$@"; }
else
    sha256() { shasum -a 256 "$@"; }   # macOS
fi

notes_for() {
    case "$1" in
        corepop-x86_64-linux)
            echo "x86-64 Linux (LP64, glibc); upstream backend" ;;
        corepop-aarch64-linux)
            echo "AArch64 Linux, generic armv8-a; built on Raspberry Pi 5 (16 KB pages -- loads on 4 KB kernels too); re-blessed 2026-10 with the struct STATB layout fix" ;;
        corepop-aarch64-darwin)
            echo "Apple Silicon macOS (Mach-O, MAP_JIT); needs the allow-jit entitlement path, see PORTING-ARM64-M-SILICON-OSX.md; re-blessed 2026-10 with the struct STATB layout fix" ;;
        corepop-riscv64-linux)
            echo "RISC-V RV64GC Linux (lp64d); built on a Cloud-V riscv64 host; re-blessed 2026-10 with the struct STATB layout fix" ;;
        *)  echo "" ;;
    esac
}

commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)

mkdir -p "$out"
found=0
for seed in "$seeds"/corepop-*; do
    [ -f "$seed" ] || continue
    cp "$seed" "$out/"
    chmod 755 "$out/$(basename "$seed")"
    found=1
done
[ "$found" = 1 ] || { echo "no corepop-* seeds under $seeds" >&2; exit 1; }

cd "$out"

sha256 corepop-* > SHA256SUMS

# manifest.json -- one entry per asset, plus the source commit
{
    printf '{\n  "source_commit": "%s",\n  "corepops": [\n' "$commit"
    first=1
    for f in corepop-*; do
        name=$f
        # corepop-<arch>-<os>
        arch=${f#corepop-}; os=${arch#*-}; arch=${arch%%-*}
        sum=$(sha256 "$f" | cut -d' ' -f1)
        size=$(wc -c < "$f" | tr -d ' ')
        [ "$first" = 1 ] || printf ',\n'
        first=0
        printf '    { "name": "%s", "arch": "%s", "os": "%s", "size": %s,\n      "sha256": "%s",\n      "notes": "%s" }' \
            "$name" "$arch" "$os" "$size" "$sum" "$(notes_for "$f")"
    done
    printf '\n  ]\n}\n'
} > manifest.json

{
    echo "Seed \`corepop\` binaries for bootstrapping a Poplog build"
    echo "(see INSTALL and PORTING-POPLOG.md part 6).  Install as"
    echo '`target/pop/corepop`, then run `./configure && make`.'
    echo
    echo "Built from commit \`$commit\`."
    echo
    echo "| asset | notes | sha256 |"
    echo "|---|---|---|"
    for f in corepop-*; do
        sum=$(sha256 "$f" | cut -d' ' -f1)
        echo "| \`$f\` | $(notes_for "$f") | \`$sum\` |"
    done
    echo
    echo "Verify with: \`sha256sum -c SHA256SUMS\`"
} > RELEASE_NOTES.md

echo "assembled $(ls corepop-* | wc -l | tr -d ' ') corepops in $out:"
cat SHA256SUMS
