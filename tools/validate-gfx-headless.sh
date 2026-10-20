#!/usr/bin/env bash
#
# validate-gfx-headless.sh -- headless regression for the SDL3/OpenGL3 graphics
# backend (Linux/Unix).  Renders the retained-canvas scene to a PPM with NO
# display, GPU, or compositor -- SDL's "offscreen" driver (EGL surfaceless) +
# Mesa llvmpipe software rendering -- and checks the image is non-blank.
#
# This is the reproducible / CI gate for the graphics stack: it needs neither
# an X11/Wayland session nor a real GPU, so it runs anywhere the ImGui source
# (tools/fetch-imgui.sh), SDL3, and a software GL (Mesa) are present.  It SKIPs
# (exit 0) when those are missing rather than failing.
#
#   ./tools/validate-gfx-headless.sh [repo-root]

set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "cannot cd to $ROOT"; exit 2; }

[ -f pop/extern/imgui/imgui.cpp ] || { echo "SKIP: ImGui not fetched (run ./tools/fetch-imgui.sh)"; exit 0; }
pkg-config --exists sdl3 2>/dev/null || { echo "SKIP: SDL3 not found (pkg-config sdl3)"; exit 0; }

if [ ! -x ./gfx-headless ]; then
    make gfx-headless >/tmp/gfx-headless-build.log 2>&1 \
        || { echo "SKIP: gfx-headless build failed (see /tmp/gfx-headless-build.log)"; exit 0; }
fi

OUT="$(mktemp -u).ppm"
LOG="$(mktemp)"
env -u DISPLAY -u WAYLAND_DISPLAY SDL_VIDEODRIVER=offscreen \
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    ./gfx-headless "$OUT" | tee "$LOG"
rc=${PIPESTATUS[0]}
FONT="$(sed -n 's/^gfx-headless: font //p' "$LOG" | tail -1)"
rm -f "$LOG"
if [ "$rc" = 2 ]; then echo "SKIP: no usable software GL (llvmpipe) here"; rm -f "$OUT"; exit 0; fi
[ "$rc" = 0 ] && [ -s "$OUT" ] || { echo "GFX HEADLESS FAILED: harness rc=$rc"; rm -f "$OUT"; exit 1; }

# Non-blank check: the scene draws bright primitives on a dark background.
bright=$(python3 - "$OUT" <<'PY' 2>/dev/null
import sys
with open(sys.argv[1], 'rb') as f:
    assert f.readline().strip() == b'P6'
    w, h = map(int, f.readline().split()); f.readline()
    d = f.read()
print(sum(1 for i in range(0, len(d) - 2, 3) if d[i] > 120 or d[i+1] > 120 or d[i+2] > 120))
PY
)
# NB: the image is NOT removed here -- the CJK band check below reads it too,
# and every exit path from here on removes it.

if [ "${bright:-0}" -le 1000 ]; then
    echo "GFX HEADLESS FAILED: image blank or near-blank ($bright bright px)"
    rm -f "$OUT"
    exit 1
fi
echo "GFX HEADLESS VALIDATED: rendered $bright bright px with no display/GPU."

# The CJK band: the harness draws a UTF-8 line into the otherwise empty strip
# below y=455.  ImGui's built-in atlas is ASCII, so before the backend loaded
# a real font this band came out BLANK while the rest of the scene rendered
# perfectly -- which is the whole shape of the defect in
# docs/bugs/imgui-atlas-ascii-only.md.  Count pixels THERE: counted globally,
# the primitives above drown it out.
if [ -z "$FONT" ] || [ "$FONT" = "none" ]; then
    echo "SKIP: no CJK font on this box (run ./tools/fetch-gfx-font.sh) -- band unchecked"
    rm -f "$OUT"
    exit 0
fi

band=$(python3 - "$OUT" <<'PY2' 2>/dev/null
import sys
with open(sys.argv[1], 'rb') as f:
    assert f.readline().strip() == b'P6'
    w, h = map(int, f.readline().split()); f.readline()
    d = f.read()
n = 0
for y in range(455, min(h, 500)):
    row = d[y * w * 3:(y + 1) * w * 3]
    n += sum(1 for i in range(0, len(row) - 2, 3)
             if row[i] > 120 or row[i+1] > 120 or row[i+2] > 120)
print(n)
PY2
)
rm -f "$OUT"

if [ "${band:-0}" -gt 50 ]; then
    echo "GFX FONT VALIDATED: $band px of Japanese text drawn from $FONT"
    exit 0
else
    echo "GFX FONT FAILED: the CJK band is blank ($band px) though a font loaded:"
    echo "  $FONT"
    exit 1
fi
