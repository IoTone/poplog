#!/usr/bin/env bash
#
# fetch-gfx-font.sh -- vendor one CJK-capable font for the experimental
# graphics backends (configure --experimental-gfx[=metal|sdl]).
#
# WHY: Dear ImGui's built-in atlas is ProggyClean, which is ASCII.  Poplog's
# pop_gfx_draw_text() takes UTF-8 (so does ImGui's text API), so without a
# real font gfx_text(x, y, c, 'あ') draws nothing at all and reports no error.
# See docs/bugs/imgui-atlas-ascii-only.md and pop/extern/lib/imgui_font.cpp.
#
# NO font is committed to the repository: like tools/fetch-imgui.sh, this
# pulls a *pinned* file into a gitignored directory.  Noto Sans JP Regular,
# SIL Open Font License 1.1, from the Noto CJK release.
#
#   ./tools/fetch-gfx-font.sh [--force]
#
# Env overrides:
#   DEST          destination dir (default pop/extern/fonts)
#   GFX_FONT_REF  noto-cjk release tag to pin (default below)
#
# WHY THE STATIC FACE AND NOT THE VARIABLE ONE: Google Fonts ships Noto Sans
# JP as a single NotoSansJP[wght].ttf, which is smaller and tempting.  ImGui
# rasterises with stb_truetype, which has no variable-axis support, so it
# renders the font's default instance -- a light weight.  Measured in the
# headless harness, same string, same size: the variable file peaked at
# intensity 205 with 1 pixel above 200, while this static Regular peaked at
# 255 with 213 pixels above 200, matching the system Noto CJK exactly.  Thin
# strokes are exactly what a learner reading kanji cannot afford.
#
# At run time an explicit $POPLOG_GFX_FONT always wins, and if nothing is
# fetched the backend falls back to the OS's own CJK font before giving up on
# ASCII, so this script is a recommendation rather than a requirement.

set -euo pipefail

# Pinned by RELEASE TAG: the same bytes every time.
GFX_FONT_REF="${GFX_FONT_REF:-Sans2.004}"
DEST="${DEST:-pop/extern/fonts}"
FONT_NAME="NotoSansJP-Regular.otf"
ZIP_NAME="16_NotoSansJP.zip"
ZIP_SHA256="2bbdd2c20f30670b39ca735c96d75f1fdabdb348103e43b820cf17701fd22b18"
FONT_SHA256="dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
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

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    fi
}

URL="https://github.com/notofonts/noto-cjk/releases/download/${GFX_FONT_REF}/${ZIP_NAME}"

echo "Fetching Noto Sans JP Regular (SIL OFL 1.1)"
echo "  from noto-cjk ${GFX_FONT_REF}"
echo "  into $DEST/"

work="$(mktemp -d "${TMPDIR:-/tmp}/notosansjp.XXXXXX")"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/$ZIP_NAME" "$URL"

got="$(sha256_of "$work/$ZIP_NAME")"
if [ -z "$got" ]; then
    echo "  (no shasum/sha256sum -- skipping the checksum)" >&2
elif [ "$got" != "$ZIP_SHA256" ]; then
    echo "fetch-gfx-font: CHECKSUM MISMATCH on $ZIP_NAME -- refusing to install" >&2
    echo "  expected $ZIP_SHA256" >&2
    echo "  got      $got" >&2
    exit 1
fi

# Only the Regular face and the licence; the other eight weights stay in the
# archive, which is thrown away with the work directory.
unzip -q -o -j "$work/$ZIP_NAME" "$FONT_NAME" LICENSE -d "$work/out"

got="$(sha256_of "$work/out/$FONT_NAME")"
if [ -n "$got" ] && [ "$got" != "$FONT_SHA256" ]; then
    echo "fetch-gfx-font: CHECKSUM MISMATCH on $FONT_NAME -- refusing to install" >&2
    echo "  expected $FONT_SHA256" >&2
    echo "  got      $got" >&2
    exit 1
fi

mkdir -p "$DEST"
mv "$work/out/$FONT_NAME" "$DEST/$FONT_NAME"
mv "$work/out/LICENSE" "$DEST/LICENSE"

echo
echo "Done -- $DEST/$FONT_NAME ($(wc -c < "$DEST/$FONT_NAME" | tr -d ' ') bytes, gitignored)"
echo "Licence alongside it in $DEST/LICENSE."
echo "Check it with:  make gfx-font-test && ./gfx-font-test"
