/* Poplog <-> Dear ImGui glue (SDL3 + OpenGL3).  See imgui_backend.h.
 *
 * The Linux/Unix sibling of imgui_backend.mm (macOS, Metal+Cocoa).  It
 * implements the SAME extern "C" pop_gfx_* surface, so rc_graphic / popgfx
 * and everything above are byte-identical across platforms -- only the
 * platform (window/event) and renderer backends differ.
 *
 * Backend choice (see PORTING / NOTES): SDL3 as the platform layer +
 * imgui_impl_opengl3 over EGL/GLX as the renderer.
 *   - SDL3 dlopen's BOTH Wayland and X11 (and kmsdrm), picking one at run
 *     time -- so there is NO hard X11 dependency.  Force with
 *     SDL_VIDEO_DRIVER=wayland|x11|kmsdrm or SDL_HINT_VIDEO_DRIVER.
 *   - OpenGL 3.0 / GLSL 130 is the broadest target: real GPUs, and Mesa
 *     llvmpipe software rendering for headless/CI.  (Not SDL_gpu/Vulkan,
 *     which is Vulkan-only on Linux with no software path.)
 *
 * Compile as C++ (no ObjC).  Links against SDL3 + libGL.  imgui_impl_opengl3
 * carries its own GL function loader, so no glad/glew/epoxy is needed.
 *
 * The CANVAS is a retained display list (g_canvas): pop_gfx_draw_* append to
 * it, frame_begin replays it onto the background draw list every frame, and
 * pop_gfx_clear() wipes it -- so drawing persists like Xpw/rc_graphic.  This
 * lower half is identical to the macOS backend by construction.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_opengl.h>

#include <vector>
#include <string>
#include <cmath>
#include <cstdio>

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_opengl3.h"
#include "imgui_backend.h"

/* --- retained canvas --------------------------------------------------- */
enum GfxKind { GK_POINT, GK_LINE, GK_RECT, GK_FILLRECT,
               GK_CIRCLE, GK_FILLCIRCLE, GK_ARC, GK_TEXT };
struct GfxCmd {
    GfxKind     kind;
    float       a, b, c, d, e, f;   /* geometry (meaning per kind)        */
    ImU32       col;
    std::string text;
};
static std::vector<GfxCmd> g_canvas;

static void canvas_replay()
{
    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    for (const GfxCmd &g : g_canvas) {
        switch (g.kind) {
        case GK_POINT:      dl->AddCircleFilled(ImVec2(g.a, g.b), 1.5f, g.col, 8); break;
        case GK_LINE:       dl->AddLine(ImVec2(g.a, g.b), ImVec2(g.c, g.d), g.col, g.e); break;
        case GK_RECT:       dl->AddRect(ImVec2(g.a, g.b), ImVec2(g.c, g.d), g.col, 0.0f, 0, g.e); break;
        case GK_FILLRECT:   dl->AddRectFilled(ImVec2(g.a, g.b), ImVec2(g.c, g.d), g.col); break;
        case GK_CIRCLE:     dl->AddCircle(ImVec2(g.a, g.b), g.c, g.col, 0, g.e); break;
        case GK_FILLCIRCLE: dl->AddCircleFilled(ImVec2(g.a, g.b), g.c, g.col, 0); break;
        case GK_ARC:
            dl->PathArcTo(ImVec2(g.a, g.b), g.c,
                          g.d * (float)M_PI / 180.0f, g.e * (float)M_PI / 180.0f, 0);
            dl->PathStroke(g.col, 0, g.f);
            break;
        case GK_TEXT:       dl->AddText(ImVec2(g.a, g.b), g.col, g.text.c_str()); break;
        }
    }
}

/* --- backend state ----------------------------------------------------- */
static SDL_Window   *g_window  = nullptr;
static SDL_GLContext g_glctx   = nullptr;
static bool          g_closed  = false;
static bool          g_frame_active = false;
#ifdef __APPLE__
static const char   *g_glsl_version = "#version 150";   /* core profile */
#else
static const char   *g_glsl_version = "#version 130";
#endif

int pop_gfx_init(const char *title, int width, int height)
{
    /* SDL_Init returns false on failure (e.g. no display / no compositor):
       treat that like "no Metal device" on macOS -- a graceful 0. */
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        SDL_Log("pop_gfx_init: SDL_Init failed: %s", SDL_GetError());
        return 0;
    }

    /* GL 3.0 / GLSL 130: works on GPUs and on Mesa llvmpipe (software).
       macOS only exposes GL >= 3.2 through a CORE, forward-compatible
       profile -- a 3.0 request fails to create a context there. */
#ifdef __APPLE__
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
#else
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
#endif
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

    const SDL_WindowFlags flags = SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
                                | SDL_WINDOW_HIGH_PIXEL_DENSITY;
    g_window = SDL_CreateWindow(title ? title : "Poplog",
                                width  > 0 ? width  : 1200,
                                height > 0 ? height : 720, flags);
    if (g_window == nullptr) {
        SDL_Log("pop_gfx_init: SDL_CreateWindow failed: %s", SDL_GetError());
        SDL_Quit();
        return 0;
    }

    g_glctx = SDL_GL_CreateContext(g_window);
    if (g_glctx == nullptr) {
        SDL_Log("pop_gfx_init: SDL_GL_CreateContext failed: %s", SDL_GetError());
        SDL_DestroyWindow(g_window); g_window = nullptr;
        SDL_Quit();
        return 0;
    }
    SDL_GL_MakeCurrent(g_window, g_glctx);
    SDL_GL_SetSwapInterval(1);                          /* vsync             */

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;               /* no imgui.ini      */
    ImGui::StyleColorsDark();
    /* A font with CJK coverage, BEFORE the renderer init: ImGui's own atlas
     * is ASCII, so pop_gfx_draw_text() accepted UTF-8 and drew nothing for
     * it (imgui_font.cpp). */
    pop_gfx_font_init();
    ImGui_ImplSDL3_InitForOpenGL(g_window, g_glctx);
    ImGui_ImplOpenGL3_Init(g_glsl_version);

    SDL_ShowWindow(g_window);
    g_closed = false;
    return 1;
}

void pop_gfx_poll(void)
{
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        ImGui_ImplSDL3_ProcessEvent(&ev);
        if (ev.type == SDL_EVENT_QUIT)
            g_closed = true;
        else if (ev.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED
                 && g_window != nullptr
                 && ev.window.windowID == SDL_GetWindowID(g_window))
            g_closed = true;
    }
}

int pop_gfx_should_close(void) { return g_closed ? 1 : 0; }

int pop_gfx_frame_begin(void)
{
    pop_gfx_poll();
    if (g_window == nullptr)
        return 0;
    /* Skip drawing while minimized (no drawable), mirroring the macOS
       "no currentRenderPassDescriptor" early-out. */
    if (SDL_GetWindowFlags(g_window) & SDL_WINDOW_MINIMIZED) {
        SDL_Delay(10);
        return 0;
    }

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL3_NewFrame();        /* sets DisplaySize + framebuffer scale */
    ImGui::NewFrame();
    canvas_replay();                                   /* retained drawing  */
    g_frame_active = true;
    return 1;
}

void pop_gfx_frame_end(void)
{
    if (!g_frame_active)
        return;
    g_frame_active = false;

    ImGui::Render();
    int fb_w = 0, fb_h = 0;
    SDL_GetWindowSizeInPixels(g_window, &fb_w, &fb_h);
    glViewport(0, 0, fb_w, fb_h);
    glClearColor(0.10f, 0.10f, 0.12f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    SDL_GL_SwapWindow(g_window);
}

/* Headless capture: render one frame of the retained canvas to the current
 * GL framebuffer and read it back to a binary PPM (P6).  No window swap, so
 * it works under the SDL "offscreen" video driver (EGL surfaceless) with Mesa
 * llvmpipe -- i.e. no display, no GPU, no compositor.  This is the CI /
 * regression primitive for the graphics stack on Linux.  Returns 1 on ok. */
extern "C" int pop_gfx_render_to_ppm(const char *path)
{
    if (g_window == nullptr || path == nullptr)
        return 0;
    pop_gfx_poll();
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
    canvas_replay();
    ImGui::Render();

    int w = 0, h = 0;
    SDL_GetWindowSizeInPixels(g_window, &w, &h);
    glViewport(0, 0, w, h);
    glClearColor(0.10f, 0.10f, 0.12f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    glFinish();

    std::vector<unsigned char> rgba((size_t) w * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());

    FILE *fp = fopen(path, "wb");
    if (!fp) return 0;
    fprintf(fp, "P6\n%d %d\n255\n", w, h);
    /* GL origin is bottom-left; PPM is top-down -- flip rows. */
    for (int y = h - 1; y >= 0; --y) {
        const unsigned char *row = rgba.data() + (size_t) y * w * 4;
        for (int x = 0; x < w; ++x)
            fwrite(row + (size_t) x * 4, 1, 3, fp);   /* RGB, drop A */
    }
    fclose(fp);
    return 1;
}

void pop_gfx_shutdown(void)
{
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    if (g_glctx)  { SDL_GL_DestroyContext(g_glctx); g_glctx = nullptr; }
    if (g_window) { SDL_DestroyWindow(g_window);    g_window = nullptr; }
    SDL_Quit();
    g_canvas.clear();
}

/* ====================================================================== *
 *  Everything below is platform-agnostic: identical to imgui_backend.mm. *
 * ====================================================================== */

/* --- retained canvas drawing ------------------------------------------ */
void pop_gfx_clear(void) { g_canvas.clear(); }

/* mark/rewind: undo canvas additions (e.g. rubber-band lines) by
   truncating the display list back to an earlier length */
int  pop_gfx_mark(void) { return (int) g_canvas.size(); }
void pop_gfx_rewind(int mark)
{
    if (mark >= 0 && (size_t) mark <= g_canvas.size())
        g_canvas.resize((size_t) mark);
}

uint32_t pop_gfx_rgba(int r, int g, int b, int a) { return IM_COL32(r, g, b, a); }

static void push(GfxKind k, float a, float b, float c, float d, float e, float f,
                 ImU32 col, const char *t)
{
    GfxCmd g; g.kind = k; g.a = a; g.b = b; g.c = c; g.d = d; g.e = e; g.f = f;
    g.col = col; if (t) g.text = t;
    g_canvas.push_back(g);
}

void pop_gfx_draw_point(float x, float y, uint32_t c)
{ push(GK_POINT, x, y, 0, 0, 0, 0, c, NULL); }

void pop_gfx_draw_line(float x0, float y0, float x1, float y1, uint32_t c, float t)
{ push(GK_LINE, x0, y0, x1, y1, t, 0, c, NULL); }

void pop_gfx_draw_rect(float x0, float y0, float x1, float y1, uint32_t c, float t)
{ push(GK_RECT, x0, y0, x1, y1, t, 0, c, NULL); }

void pop_gfx_fill_rect(float x0, float y0, float x1, float y1, uint32_t c)
{ push(GK_FILLRECT, x0, y0, x1, y1, 0, 0, c, NULL); }

void pop_gfx_draw_circle(float cx, float cy, float r, uint32_t c, float t)
{ push(GK_CIRCLE, cx, cy, r, 0, t, 0, c, NULL); }

void pop_gfx_fill_circle(float cx, float cy, float r, uint32_t c)
{ push(GK_FILLCIRCLE, cx, cy, r, 0, 0, 0, c, NULL); }

void pop_gfx_draw_arc(float cx, float cy, float r, float a0, float a1, uint32_t c, float t)
{ push(GK_ARC, cx, cy, r, a0, a1, t, c, NULL); }

void pop_gfx_draw_text(float x, float y, uint32_t c, const char *s)
{ if (s) push(GK_TEXT, x, y, 0, 0, 0, 0, c, s); }

/* --- immediate panels -------------------------------------------------- */
int  pop_gfx_begin(const char *title) { return ImGui::Begin(title ? title : "##win") ? 1 : 0; }
void pop_gfx_end(void)                { ImGui::End(); }
void pop_gfx_label(const char *s)     { if (s) ImGui::TextUnformatted(s); }
int  pop_gfx_button(const char *label){ return ImGui::Button(label ? label : "##btn") ? 1 : 0; }

int  pop_gfx_checkbox(const char *label, int v)
{ bool b = (v != 0); ImGui::Checkbox(label ? label : "##chk", &b); return b ? 1 : 0; }

/* --- input ------------------------------------------------------------- */
float pop_gfx_mouse_x(void) { return ImGui::GetIO().MousePos.x; }
float pop_gfx_mouse_y(void) { return ImGui::GetIO().MousePos.y; }
int   pop_gfx_mouse_down(int button)
{ return (button >= 0 && button < 5 && ImGui::GetIO().MouseDown[button]) ? 1 : 0; }

/* --- introspection / stats --------------------------------------------- */
float pop_gfx_fps(void)
{
    /* ImGui reports FLT_MAX until it has accumulated frame timing; clamp that
       (and any NaN/inf) to 0 so callers never see a value that overflows a
       single-float Pop decimal. */
    float f = ImGui::GetIO().Framerate;
    return (f > 0.0f && f < 1.0e5f) ? f : 0.0f;
}

const char *pop_gfx_spec(void)
{
    static char s[224] = {0};
    if (s[0] == '\0') {
        const char *r = (const char *)glGetString(GL_RENDERER);
        const char *v = (const char *)glGetString(GL_VERSION);
        snprintf(s, sizeof s, "SDL3 + OpenGL - %s (%s)", r ? r : "?", v ? v : "?");
    }
    return s;
}
