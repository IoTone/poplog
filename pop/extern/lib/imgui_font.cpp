/* Poplog <-> Dear ImGui: the font the atlas does not load by itself.
 *
 * ImGui's built-in atlas is ProggyClean, which is ASCII.  Both backends
 * (imgui_backend.mm, imgui_backend_sdl.cpp) used to create a context and go
 * straight to the renderer init, so the atlas held ASCII and nothing else --
 * while pop_gfx_draw_text() happily takes UTF-8, because ImGui's text API
 * does.  The result was that gfx_text(x, y, c, 'あ') drew NOTHING: the string
 * was decoded, the codepoint had no glyph, and a missing glyph is not an
 * error.  Silence, in other words, for every language Poplog's own utf8
 * library exists to support.
 *
 * So: load a real font at init.  Since Dear ImGui 1.92 the atlas is dynamic
 * and rasterises glyphs on demand, so there are no ranges to declare and
 * nothing to pre-bake -- ImFontConfig::GlyphRanges is marked *LEGACY* in
 * imgui.h.  The whole fix is to hand the atlas a font file that CONTAINS the
 * glyphs, which is why this file is mostly about finding one.
 *
 * Search order (first readable file wins):
 *   1. $POPLOG_GFX_FONT              -- an explicit choice always wins
 *   2. $usepop/pop/extern/fonts/     -- fetched by tools/fetch-gfx-font.sh
 *   3. pop/extern/fonts/             -- same, run from the build tree
 *   4. the OS's own CJK font         -- so a user who fetched nothing still
 *                                       gets Japanese if the system has it
 *
 * A STATIC face is what gets fetched, deliberately.  stb_truetype, which is
 * what ImGui rasterises with, has no variable-axis support: hand it a
 * variable font and it renders the default instance, which for Noto Sans JP
 * is a light weight.  Measured headless, same string and size, the variable
 * file peaked at intensity 205 (1 px above 200) against the static Regular's
 * 255 (213 px above 200).  Thin strokes are the one thing a learner reading
 * kanji cannot afford.
 *
 * Nothing is bundled in the repository: the font is fetched at build time
 * like ImGui itself (tools/fetch-gfx-font.sh pins Noto Sans JP, SIL OFL 1.1,
 * by commit and sha256), and pop/extern/fonts/ is gitignored.
 *
 * If no file is found we fall back to AddFontDefault() -- the old behaviour,
 * ASCII only -- and return 0, so gfx_init can say so once rather than
 * leaving the user to discover it a glyph at a time.
 */

#include "imgui.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static char g_font_path[1024] = "";
static float g_font_size = 18.0f;

static bool readable(const char *path)
{
    if (path == NULL || *path == '\0')
        return false;
    FILE *f = fopen(path, "rb");
    if (f == NULL)
        return false;
    fclose(f);
    return true;
}

extern "C" const char *pop_gfx_font_path(void)
{
    return g_font_path[0] != '\0' ? g_font_path : NULL;
}

extern "C" float pop_gfx_font_size(void)
{
    return g_font_size;
}

extern "C" int pop_gfx_font_init(void)
{
    ImGuiIO &io = ImGui::GetIO();
    const char *cands[16];
    static char vendored[1024], vendored2[1024];
    int n = 0;

    g_font_path[0] = '\0';

    const char *env = getenv("POPLOG_GFX_FONT");
    if (env != NULL && *env != '\0')
        cands[n++] = env;

    const char *usepop = getenv("usepop");
    if (usepop != NULL && *usepop != '\0') {
        snprintf(vendored, sizeof vendored,
                 "%s/pop/extern/fonts/NotoSansJP-Regular.otf", usepop);
        cands[n++] = vendored;
        snprintf(vendored2, sizeof vendored2,
                 "%s/pop/extern/fonts/NotoSansJP.ttf", usepop);
        cands[n++] = vendored2;          /* what older trees fetched */
    }
    cands[n++] = "pop/extern/fonts/NotoSansJP-Regular.otf";
    cands[n++] = "pop/extern/fonts/NotoSansJP.ttf";

#ifdef __APPLE__
    /* Shipped with macOS; both cover kana and common kanji. */
    cands[n++] = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf";
    cands[n++] = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc";
    cands[n++] = "/Library/Fonts/Arial Unicode.ttf";
#else
    /* Debian/Ubuntu, Fedora, Arch, and the Noto JP-only package. */
    cands[n++] = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
    cands[n++] = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc";
    cands[n++] = "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc";
    cands[n++] = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
    cands[n++] = "/usr/share/fonts/opentype/ipafont-gothic/ipagp.ttf";
#endif

    for (int i = 0; i < n; i++) {
        if (!readable(cands[i]))
            continue;
        ImFontConfig cfg;
        /* A .ttc is a collection: face 0 is the regular weight in every
         * candidate above.  Harmless for a plain .ttf/.otf. */
        cfg.FontNo = 0;
        /* Do not assert if the file turns out not to be a font: a user's
         * POPLOG_GFX_FONT, or an OS font we guessed at, must not be able
         * to kill the process.  AddFontFromFileTTF returns NULL instead. */
        cfg.Flags |= ImFontFlags_NoLoadError;
        ImFont *font = io.Fonts->AddFontFromFileTTF(cands[i], g_font_size, &cfg);
        if (font != NULL) {
            strncpy(g_font_path, cands[i], sizeof g_font_path - 1);
            g_font_path[sizeof g_font_path - 1] = '\0';
            return 1;
        }
    }

    io.Fonts->AddFontDefault();         /* ASCII only -- the old behaviour */
    return 0;
}
