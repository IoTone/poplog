# gfx_text draws nothing outside ASCII: no backend loads a font

Found 2026-10-19 while designing a Japanese/English tutor
(`examples/langpop/`), by grepping the graphics backends for font handling
before relying on them to draw kana — the grep came back empty.
**Fixed** 2026-10-19 (see "Fix" below); the atlas half is verified by a
standalone test that runs with no display, and the pixel half by the
headless validator on the SDL path. Pre-existing: the backends have never
loaded a font.

## Symptom

```pop11
uses popgfx;
gfx_init('langpop', 800, 600);
gfx_text(40, 40, gfx_rgb(255, 255, 255), 'あいう');   ;;; draws nothing
gfx_text(40, 70, gfx_rgb(255, 255, 255), 'abc');      ;;; draws fine
```

No error, no warning, no mishap. The string is valid UTF-8, `lib utf8`
reports three characters, the backend accepts it, ImGui decodes it — and
every glyph is absent from the atlas, so the result is blank space of the
right width. A caller has no way to tell this from "the text is there but
off-screen" or "my colour is wrong".

## Cause

Both backends create a context and go straight to the renderer:

```objc
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = NULL;
    ImGui::StyleColorsDark();
    ImGui_ImplMetal_Init(g_device);        /* imgui_backend.mm */
```

With no font added, `ImFontAtlas` loads its built-in default —
ProggyClean, 13px, ASCII. Nothing else was ever going to render. Grepping
`pop/extern/lib/` for `AddFont`, `Fonts->`, `.ttf` or `glyph` before the
fix returned nothing at all, in either backend or the headless harness.

The reason this survived: every graphics demo in the tree (`tenprint.p`,
`cube3d.p`, `poplog_letters.p`, `impossible_triangle.p`, `vectrex.p`) is
either pure geometry or ASCII labels, and `poplog_letters.p` draws its
giant letters out of *rectangles*, not glyphs. The one feature that would
have caught it — Japanese text — is also the one the backend was never
asked for. See `docs/2030plan.md` 4.4, which plans exactly that.

## Fix

A shared `pop/extern/lib/imgui_font.cpp`, called from both backends
between `CreateContext()` and the renderer init:

```c
int pop_gfx_font_init(void);      /* 1 = a font file was loaded, 0 = ASCII */
const char *pop_gfx_font_path(void);
```

Since Dear ImGui **1.92** the atlas is dynamic: glyphs are rasterised on
demand and `ImFontConfig::GlyphRanges` is marked `*LEGACY*` in `imgui.h`.
So there are no ranges to declare and nothing to pre-bake — the entire
fix is to hand the atlas a font file that contains the glyphs. The file is
found by searching, in order:

| | |
| --- | --- |
| `$POPLOG_GFX_FONT` | an explicit choice always wins |
| `$usepop/pop/extern/fonts/NotoSansJP.ttf` | fetched by `tools/fetch-gfx-font.sh` |
| `pop/extern/fonts/NotoSansJP.ttf` | the same, run from the build tree |
| the OS's own CJK font | Arial Unicode / Hiragino on macOS; Noto CJK or IPAex on Linux |

and if none is readable it calls `AddFontDefault()` — the old behaviour —
and returns 0, which `gfx_init` now reports **once**, rather than leaving
it to be discovered a glyph at a time:

```
;;; popgfx: no font file found -- text is ASCII only.
;;; popgfx: run tools/fetch-gfx-font.sh, or set POPLOG_GFX_FONT.
```

`ImFontFlags_NoLoadError` is set on the font config, so a `POPLOG_GFX_FONT`
that turns out not to be a font returns NULL instead of asserting inside
the process.

No font is committed. `tools/fetch-gfx-font.sh` pins Noto Sans JP (SIL
OFL 1.1) by **commit** and verifies a **sha256** before installing, into a
gitignored `pop/extern/fonts/`, with `OFL.txt` fetched alongside it — the
same posture as `tools/fetch-imgui.sh`.

## Verifying

**The atlas, anywhere** (no window, no GPU, no SDL, no Poplog — ImGui core
only), asserting both halves, so it would have failed before the fix:

```
./tools/fetch-imgui.sh && ./tools/fetch-gfx-font.sh
make gfx-font-test && ./gfx-font-test
```

```
ok    default font has 'A'
ok    default font has NO HIRAGANA A (the defect)
ok    default font has NO KATAKANA A
ok    default font has NO KANJI 'day'
font: pop/extern/fonts/NotoSansJP.ttf
ok    loaded font still has 'A'
ok    loaded font has HIRAGANA A
ok    loaded font has KATAKANA A
ok    loaded font has HIRAGANA N
ok    loaded font has KANJI 'day'
ok    loaded font has KANJI 'book'
ok    loaded font has the ideographic comma
ok    'あいう' measures wider than one glyph
      'あいう' measures 40.3 x 18.0 px at 18px
ALL PASS
```

A glyph counts only if it exists **and** covers area (`Visible`, non-zero
box), so an empty box does not pass.

**The pixels** (`tools/validate-gfx-headless.sh`, Linux/SDL3 + llvmpipe):
`imgui_headless.cpp` now draws `日本語 ひらがな カタカナ 1234` into the
otherwise empty strip below y=455, and the validator counts bright pixels
**in that band**. Counted globally, as before, the geometry above drowns
it out — the band is the point. If no font is available on the box the
harness prints `font none` and the band check SKIPs rather than fails.

## Platforms

The atlas test and the Metal link were run here (macOS 15, arm64):
`make gfx-smoke` builds and links the whole Metal stack with the loader
in it. The SDL3 path is a one-line call in the same place and was
**not compiled here** — no SDL3 on this machine — so the Linux CI run is
what confirms it, along with the band check above. The band-counting logic
itself was exercised against synthetic PPMs with and without text (2,560
px vs 0 px, pass vs fail).

## What it would have cost langpop

Everything the Japanese side renders: kana cards, stroke-order diagrams,
the mnemonic images, any TUI that shows a word. The design document had
already budgeted "a few days" to add font loading before any card could be
drawn; the actual change is ~110 lines of C++ and a fetch script, because
1.92's dynamic atlas removed the hard part.
