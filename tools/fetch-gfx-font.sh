#!/usr/bin/env bash
#
# fetch-gfx-font.sh -- vendor one CJK-capable font for the experimental
# graphics backends (configure --experimental-gfx / --experimental-gfx-sdl).
#
# WHY: Dear ImGui's built-in atlas is ProggyClean, which is ASCII.  Poplog's
# pop_gfx_draw_text() takes UTF-8 (so does ImGui's text API), so without a
# real font gfx_text(x, y, c, 'あ') draws nothing at all and reports no error.
# See docs/bugs/imgui-atlas-ascii-only.md and pop/extern/lib/imgui_font.cpp.
#
# NO font is committed to the repository: like tools/fetch-imgui.sh, this
# pulls a *pinned* file into a gitignored directory.  Noto Sans JP, SIL Open
# Font License 1.1 -- redistributable, and the licence is fetched next to it.
#
#   ./tools/fetch-gfx-font.sh [--force]
#
# Env overrides:
#   DEST          destination dir (default pop/extern/fonts)
#   GFX_FONT_REF  google/fonts commit to pin (default below)
#
# At run time an explicit $POPLOG_GFX_FONT always wins, and if nothing is
# fetched the backend falls back to the OS's own CJK font before giving up on
# ASCII, so this script is a recommendation rather than a requirement.

set -euo pipefail

# Pinned by COMMIT, not by branch: the same bytes every time.
GFX_FONT_REF="${GFX_FONT_REF:-295d98a7a0c17c68f1341eaeea354e7960ea70d3}"
DEST="${DEST:-pop/extern/fonts}"
FONT_NAME="NotoSansJP.ttf"
# sha256 of ofl/notosansjp/NotoSansJP[wght].ttf at the commit above
FONT_SHA256="c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Run from the repo root regardless of where we were invoked from.
cd "$(dirname "$0")/.."

if [ -f "$DEST/$FONT_NAME" ] && [ "$FORCE" -eq 0 ]; then
    echo "Already present: $DEST/$FONT_NAME  (--force to re-fetch)"
    exit 0
fi

BASE="https://raw.githubusercontent.com/google/fonts/${GFX_FONT_REF}/ofl/notosansjp"
mkdir -p "$DEST"

echo "Fetching Noto Sans JP (SIL OFL 1.1)"
echo "  from google/fonts @ ${GFX_FONT_REF}"
echo "  into $DEST/"

tmp="$(mktemp "${TMPDIR:-/tmp}/notosansjp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# The file name contains brackets, which must stay percent-encoded in the URL.
curl -fsSL -o "$tmp" "${BASE}/NotoSansJP%5Bwght%5D.ttf"

if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
elif command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
else
    got=""
    echo "  (no shasum/sha256sum -- skipping the checksum)" >&2
fi

if [ -n "$got" ] && [ "$got" != "$FONT_SHA256" ]; then
    echo "fetch-gfx-font: CHECKSUM MISMATCH -- refusing to install" >&2
    echo "  expected $FONT_SHA256" >&2
    echo "  got      $got" >&2
    exit 1
fi

mv "$tmp" "$DEST/$FONT_NAME"
trap - EXIT
curl -fsSL -o "$DEST/OFL.txt" "${BASE}/OFL.txt"

echo
echo "Done -- $DEST/$FONT_NAME ($(wc -c < "$DEST/$FONT_NAME" | tr -d ' ') bytes, gitignored)"
echo "Licence alongside it in $DEST/OFL.txt."
echo "Check it with:  make gfx-font-test && ./gfx-font-test"
