#!/bin/sh
# release-sizes.sh — record how big a release is, and how big it used to be.
#
#   tools/release-sizes.sh                 measure dist/ and append to the ledger
#   tools/release-sizes.sh --print         print the table without appending
#   tools/release-sizes.sh --notes         print a markdown block for release notes
#
# Two numbers per platform, because they answer different questions:
#
#   engine   target/pop/basepop11 -- what actually got compiled and linked.
#            Only changes to pop/src or pop/extern move this.
#   tarball  the whole download, which also carries pop/lib as SOURCE
#            (loaded at runtime by `uses`), the skill, the MCP and LSP
#            servers and the story files. Libraries grow this and not the
#            engine: the Z-machine added 94 KB of source and zero bytes of
#            binary.
#
# The ledger is docs/release-sizes.md, committed, so `git log -p` on it is
# the history.
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
dist="${DIST:-$repo/dist}"
ledger="$repo/docs/release-sizes.md"
mode="${1:-append}"

date_today="$(date +%Y-%m-%d)"
commit="$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# One row per platform found in dist/.
rows=""
for t in "$dist"/pop11-skill-*.tar.gz; do
    [ -f "$t" ] || continue
    base="$(basename "$t" .tar.gz)"
    plat="${base#pop11-skill-}"
    tarbytes="$(wc -c < "$t" | tr -d ' ')"

    # the engine lives at <prefix>/target/pop/basepop11 inside the tarball
    tmp="$(mktemp -d)"
    if tar -xzf "$t" -C "$tmp" "$base/target/pop/basepop11" 2>/dev/null; then
        enginebytes="$(wc -c < "$tmp/$base/target/pop/basepop11" | tr -d ' ')"
    else
        enginebytes="?"
    fi
    rm -rf "$tmp"

    rows="$rows| $date_today | \`$commit\` | $plat | $enginebytes | $tarbytes |
"
done

[ -n "$rows" ] || { echo "release-sizes: no tarballs in $dist" >&2; exit 2; }

case "$mode" in
    --print)
        printf '%s' "$rows"
        ;;
    --notes)
        echo "### Sizes"
        echo
        echo "| platform | engine | download |"
        echo "|---|---:|---:|"
        printf '%s' "$rows" | while IFS='|' read -r _ _ _ plat eng tar _; do
            plat="$(echo "$plat" | tr -d ' ')"
            eng="$(echo "$eng" | tr -d ' ')"
            tar="$(echo "$tar" | tr -d ' ')"
            [ -n "$plat" ] || continue
            printf '| %s | %s KB | %s KB |\n' "$plat" \
                "$(( (eng + 512) / 1024 ))" "$(( (tar + 512) / 1024 ))"
        done
        echo
        echo "_Engine is \`basepop11\`; the download also carries \`pop/lib\`"
        echo "as source, the skill, the MCP and LSP servers and the story"
        echo "files. Full history: [docs/release-sizes.md](docs/release-sizes.md)._"
        ;;
    *)
        [ -f "$ledger" ] || {
            mkdir -p "$(dirname "$ledger")"
            cat > "$ledger" <<'HEADER'
# Release sizes

Appended by `tools/release-sizes.sh` on every release, so that growth is
visible rather than discovered.

**engine** is `target/pop/basepop11` — what was compiled and linked. Only
changes under `pop/src` or `pop/extern` move it.

**tarball** is the whole download, which also carries `pop/lib` as *source*
(Poplog loads libraries at runtime with `uses`), the pop11 skill, the MCP
and LSP servers, and the freely-licensed story files. A new library grows
this and not the engine — the Z-machine added 94 KB of source and zero
bytes of binary.

Sizes are bytes.

| date | commit | platform | engine | tarball |
|---|---|---|---:|---:|
HEADER
        }
        printf '%s' "$rows" >> "$ledger"
        echo "appended $(printf '%s' "$rows" | grep -c .) rows to docs/release-sizes.md"
        ;;
esac
