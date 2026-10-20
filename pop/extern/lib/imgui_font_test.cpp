/* Standalone check that the ImGui atlas can actually draw Japanese.
 *
 * No window, no GPU, no Poplog: it builds an ImGui context, bakes glyphs and
 * asks the atlas whether they exist.  That is the whole of the defect --
 * pop_gfx_draw_text() took UTF-8 and the atlas had no glyph for it -- so it
 * is the right thing to assert, and it runs anywhere clang++ does.
 *
 *   ./tools/fetch-imgui.sh && ./tools/fetch-gfx-font.sh
 *   make gfx-font-test && ./gfx-font-test
 *
 * Phase 1 shows the bug: with ImGui's default font, あ has no glyph.
 * Phase 2 shows the fix: with pop_gfx_font_init(), it has one, with pixels.
 */

#include "imgui.h"
#include "imgui_backend.h"

#include <cstdio>
#include <cstring>

static int failures = 0;

static void check(bool ok, const char *what)
{
    printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        failures++;
}

/* A glyph exists AND covers some area (so a blank box does not pass). */
static bool has_glyph(ImFont *font, unsigned int cp, float size)
{
    ImFontBaked *baked = font->GetFontBaked(size);
    if (baked == NULL)
        return false;
    ImFontGlyph *g = baked->FindGlyphNoFallback((ImWchar)cp);
    if (g == NULL)
        return false;
    return g->Visible && (g->X1 - g->X0) > 0.0f && (g->Y1 - g->Y0) > 0.0f;
}

static ImFont *start_frame(void)
{
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(640.0f, 480.0f);
    io.DeltaTime = 1.0f / 60.0f;
    /* There is no renderer here.  Since 1.92 the atlas rasterises glyphs on
     * demand and hands the backend texture updates, which is announced with
     * this flag -- the real backends (imgui_impl_metal, imgui_impl_opengl3)
     * both set it.  Without it ImGui asserts that nobody built the atlas. */
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
    ImGui::NewFrame();
    return ImGui::GetFont();
}

int main(void)
{
    const float size = 18.0f;

    /* ---- phase 1: the default atlas, i.e. the bug ---------------------- */
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    {
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = NULL;
        io.Fonts->AddFontDefault();
        ImFont *font = start_frame();
        check(has_glyph(font, 'A', size),    "default font has 'A'");
        check(!has_glyph(font, 0x3042, size), "default font has NO HIRAGANA A (the defect)");
        check(!has_glyph(font, 0x30A2, size), "default font has NO KATAKANA A");
        check(!has_glyph(font, 0x65E5, size), "default font has NO KANJI 'day'");
        ImGui::EndFrame();
    }
    ImGui::DestroyContext();

    /* ---- phase 2: the same atlas after pop_gfx_font_init() ------------- */
    ImGui::CreateContext();
    {
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = NULL;
        int loaded = pop_gfx_font_init();
        if (!loaded) {
            printf("SKIP  no font file found -- run ./tools/fetch-gfx-font.sh\n");
            printf("      (searched $POPLOG_GFX_FONT, pop/extern/fonts/, the OS fonts)\n");
            ImGui::DestroyContext();
            return failures == 0 ? 0 : 1;
        }
        printf("font: %s\n", pop_gfx_font_path());
        ImFont *font = start_frame();
        check(has_glyph(font, 'A', size),     "loaded font still has 'A'");
        check(has_glyph(font, 0x3042, size),  "loaded font has HIRAGANA A");
        check(has_glyph(font, 0x30A2, size),  "loaded font has KATAKANA A");
        check(has_glyph(font, 0x3093, size),  "loaded font has HIRAGANA N");
        check(has_glyph(font, 0x65E5, size),  "loaded font has KANJI 'day'");
        check(has_glyph(font, 0x672C, size),  "loaded font has KANJI 'book'");
        check(has_glyph(font, 0x3001, size),  "loaded font has the ideographic comma");

        /* The string the TUI would actually draw, measured: a width of zero
         * would mean we are drawing nothing however many glyphs exist. */
        ImVec2 sz = font->CalcTextSizeA(size, FLT_MAX, 0.0f, "\xe3\x81\x82\xe3\x81\x84\xe3\x81\x86");
        check(sz.x > size, "'あいう' measures wider than one glyph");
        printf("      'あいう' measures %.1f x %.1f px at %.0fpx\n", sz.x, sz.y, size);
        ImGui::EndFrame();
    }
    ImGui::DestroyContext();

    printf(failures == 0 ? "\nALL PASS\n" : "\n%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
