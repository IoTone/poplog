/* Poplog <-> Dear ImGui glue (Win32 + Direct3D 11).  See imgui_backend.h.
 *
 * The Windows sibling of imgui_backend.mm (macOS, Metal+Cocoa) and
 * imgui_backend_sdl.cpp (Linux/Unix, SDL3+OpenGL).  It implements the SAME
 * extern "C" pop_gfx_* surface, so rc_graphic / popgfx and everything above
 * are unchanged -- only the platform (window/event) and renderer differ.
 *
 * Backend choice (PORTING-X86-64-WINDOWS.md): Dear ImGui's own Win32 platform
 * backend and Direct3D 11 renderer.
 *   - Nothing to install: user32, d3d11 and d3dcompiler ship with Windows,
 *     and Cygwin's w32api package has the headers and import libraries.
 *     (Cygwin's SDL is an X11 program; it would need an X server.)
 *   - Direct3D 11 has a software rasteriser, WARP, used automatically when
 *     there is no usable GPU (a VM, a remote session) and on request with
 *     POP_GFX_RENDERER=warp.  OpenGL on such machines is often the GDI 1.1
 *     implementation, which imgui_impl_opengl3 cannot use.
 *
 * Poplog on Windows is a Cygwin program, and this file is compiled by
 * Cygwin's g++.  It uses the Win32 API directly, which a Cygwin program may
 * do; nothing here depends on Cygwin.  The window belongs to the thread that
 * calls pop_gfx_init, and its messages are pumped by pop_gfx_poll.
 *
 * Environment:
 *   POP_GFX_HEADLESS   if set, the window is created but never shown
 *   POP_GFX_RENDERER   "warp" forces the software rasteriser
 *
 * The CANVAS is a retained display list (g_canvas): pop_gfx_draw_* append to
 * it, frame_begin replays it onto the background draw list every frame, and
 * pop_gfx_clear() wipes it -- so drawing persists like Xpw/rc_graphic.  This
 * half is identical to the other backends by construction.
 */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>

#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx11.h"
#include "imgui_backend.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

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
static HWND                    g_hwnd   = nullptr;
static ID3D11Device           *g_dev    = nullptr;
static ID3D11DeviceContext    *g_ctx    = nullptr;
static IDXGISwapChain         *g_swap   = nullptr;
static ID3D11RenderTargetView *g_rtv    = nullptr;
static bool                    g_closed = false;
static bool                    g_frame_active = false;
static bool                    g_hidden = false;    /* POP_GFX_HEADLESS       */
static bool                    g_warp   = false;    /* software renderer used */
static UINT                    g_resize_w = 0, g_resize_h = 0;
static const wchar_t          *WNDCLASS_NAME = L"PoplogGfx";

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

static LRESULT WINAPI wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp))
        return 1;
    switch (msg) {
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) {
            g_resize_w = (UINT) LOWORD(lp);     /* applied in frame_begin */
            g_resize_h = (UINT) HIWORD(lp);
        }
        return 0;
    case WM_SYSCOMMAND:
        if ((wp & 0xfff0) == SC_KEYMENU)        /* no ALT application menu */
            return 0;
        break;
    case WM_CLOSE:
        /* Report it and leave the window up: Poplog decides when to shut
           down, as with the other backends. */
        g_closed = true;
        return 0;
    case WM_DESTROY:
        g_closed = true;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void make_target(void)
{
    ID3D11Texture2D *back = nullptr;
    if (SUCCEEDED(g_swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **) &back)) && back) {
        g_dev->CreateRenderTargetView(back, nullptr, &g_rtv);
        back->Release();
    }
}

static void drop_target(void)
{
    if (g_rtv) { g_rtv->Release(); g_rtv = nullptr; }
}

static bool make_device(HWND hwnd, int w, int h)
{
    DXGI_SWAP_CHAIN_DESC sd;
    ZeroMemory(&sd, sizeof sd);
    sd.BufferCount = 2;
    sd.BufferDesc.Width  = (UINT) w;
    sd.BufferDesc.Height = (UINT) h;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    const D3D_FEATURE_LEVEL want[2] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    D3D_FEATURE_LEVEL got;
    HRESULT hr = E_FAIL;
    /* POP_GFX_RENDERER=warp forces the software rasteriser (the Windows
       counterpart of Mesa llvmpipe): no GPU needed, same pixels everywhere. */
    const char *pref = getenv("POP_GFX_RENDERER");
    bool want_warp = pref && (pref[0] == 'w' || pref[0] == 'W');
    if (!want_warp)
        hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
                                           want, 2, D3D11_SDK_VERSION,
                                           &sd, &g_swap, &g_dev, &got, &g_ctx);
    if (FAILED(hr)) {
        hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0,
                                           want, 2, D3D11_SDK_VERSION,
                                           &sd, &g_swap, &g_dev, &got, &g_ctx);
        g_warp = SUCCEEDED(hr);
    }
    if (FAILED(hr))
        return false;
    make_target();
    return g_rtv != nullptr;
}

static void drop_device(void)
{
    drop_target();
    if (g_swap) { g_swap->Release(); g_swap = nullptr; }
    if (g_ctx)  { g_ctx->Release();  g_ctx  = nullptr; }
    if (g_dev)  { g_dev->Release();  g_dev  = nullptr; }
}

int pop_gfx_init(const char *title, int width, int height)
{
    if (width  <= 0) width  = 1200;
    if (height <= 0) height = 720;
    g_hidden = getenv("POP_GFX_HEADLESS") != nullptr;

    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.style = CS_CLASSDC;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, (LPCWSTR) IDC_ARROW);
    wc.lpszClassName = WNDCLASS_NAME;
    RegisterClassExW(&wc);

    /* the title arrives as UTF-8 */
    wchar_t wtitle[256];
    if (!title || !MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle, 256))
        lstrcpyW(wtitle, L"Poplog");

    /* ask for a client area of the requested size */
    RECT r = { 0, 0, width, height };
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    g_hwnd = CreateWindowW(WNDCLASS_NAME, wtitle, WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top,
                           nullptr, nullptr, inst, nullptr);
    if (g_hwnd == nullptr) {
        fprintf(stderr, "pop_gfx_init: CreateWindow failed (error %lu)\n", GetLastError());
        UnregisterClassW(WNDCLASS_NAME, inst);
        return 0;
    }
    if (!make_device(g_hwnd, width, height)) {
        fprintf(stderr, "pop_gfx_init: no Direct3D 11 device, hardware or software\n");
        drop_device();
        DestroyWindow(g_hwnd); g_hwnd = nullptr;
        UnregisterClassW(WNDCLASS_NAME, inst);
        return 0;
    }
    g_resize_w = g_resize_h = 0;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;               /* no imgui.ini      */
    ImGui::StyleColorsDark();
    /* A font with CJK coverage, BEFORE the renderer init (imgui_font.cpp). */
    pop_gfx_font_init();
    ImGui_ImplWin32_Init(g_hwnd);
    ImGui_ImplDX11_Init(g_dev, g_ctx);

    if (!g_hidden) {
        ShowWindow(g_hwnd, SW_SHOWDEFAULT);
        UpdateWindow(g_hwnd);
    }
    g_closed = false;
    return 1;
}

void pop_gfx_poll(void)
{
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0U, 0U, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (msg.message == WM_QUIT)
            g_closed = true;
    }
}

int pop_gfx_should_close(void) { return g_closed ? 1 : 0; }

static void new_frame(void)
{
    if (g_resize_w != 0 && g_resize_h != 0) {
        drop_target();
        g_swap->ResizeBuffers(0, g_resize_w, g_resize_h, DXGI_FORMAT_UNKNOWN, 0);
        g_resize_w = g_resize_h = 0;
        make_target();
    }
    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    canvas_replay();                                   /* retained drawing  */
}

static void render(void)
{
    static const float clear[4] = { 0.10f, 0.10f, 0.12f, 1.0f };
    ImGui::Render();
    g_ctx->OMSetRenderTargets(1, &g_rtv, nullptr);
    g_ctx->ClearRenderTargetView(g_rtv, clear);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
}

int pop_gfx_frame_begin(void)
{
    pop_gfx_poll();
    if (g_hwnd == nullptr || g_swap == nullptr)
        return 0;
    /* Skip drawing while minimised, as the other backends do. */
    if (IsIconic(g_hwnd)) {
        Sleep(10);
        return 0;
    }
    new_frame();
    g_frame_active = true;
    return 1;
}

void pop_gfx_frame_end(void)
{
    if (!g_frame_active)
        return;
    g_frame_active = false;
    render();
    g_swap->Present(1, 0);                              /* vsync             */
}

/* Headless capture: render one frame of the retained canvas and read it back
 * to a binary PPM (P6).  Nothing is presented, so it works with the window
 * hidden (POP_GFX_HEADLESS) and, with POP_GFX_RENDERER=warp, with no GPU.
 * The same regression primitive as the SDL backend's.  Returns 1 on ok. */
extern "C" int pop_gfx_render_to_ppm(const char *path)
{
    if (g_hwnd == nullptr || g_swap == nullptr || path == nullptr)
        return 0;
    pop_gfx_poll();
    new_frame();
    render();
    g_ctx->Flush();

    ID3D11Texture2D *back = nullptr, *copy = nullptr;
    if (FAILED(g_swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **) &back)) || !back)
        return 0;
    D3D11_TEXTURE2D_DESC td;
    back->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    int ok = 0;
    if (SUCCEEDED(g_dev->CreateTexture2D(&td, nullptr, &copy)) && copy) {
        g_ctx->CopyResource(copy, back);
        D3D11_MAPPED_SUBRESOURCE map;
        if (SUCCEEDED(g_ctx->Map(copy, 0, D3D11_MAP_READ, 0, &map))) {
            FILE *fp = fopen(path, "wb");
            if (fp) {
                fprintf(fp, "P6\n%u %u\n255\n", td.Width, td.Height);
                for (UINT y = 0; y < td.Height; ++y) {      /* already top-down */
                    const unsigned char *row = (const unsigned char *) map.pData + (size_t) y * map.RowPitch;
                    for (UINT x = 0; x < td.Width; ++x)
                        fwrite(row + (size_t) x * 4, 1, 3, fp);   /* RGB, drop A */
                }
                fclose(fp);
                ok = 1;
            }
            g_ctx->Unmap(copy, 0);
        }
        copy->Release();
    }
    back->Release();
    return ok;
}

void pop_gfx_shutdown(void)
{
    if (g_hwnd == nullptr)
        return;
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    drop_device();
    DestroyWindow(g_hwnd); g_hwnd = nullptr;
    UnregisterClassW(WNDCLASS_NAME, GetModuleHandleW(nullptr));
    g_canvas.clear();
}

/* ====================================================================== *
 *  Everything below is platform-agnostic: identical to the other backends. *
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
        char name[128] = "?";
        IDXGIDevice *xd = nullptr;
        if (g_dev && SUCCEEDED(g_dev->QueryInterface(__uuidof(IDXGIDevice), (void **) &xd)) && xd) {
            IDXGIAdapter *ad = nullptr;
            if (SUCCEEDED(xd->GetAdapter(&ad)) && ad) {
                DXGI_ADAPTER_DESC d;
                if (SUCCEEDED(ad->GetDesc(&d)))
                    WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, name, sizeof name, nullptr, nullptr);
                ad->Release();
            }
            xd->Release();
        }
        snprintf(s, sizeof s, "Win32 + Direct3D 11 - %s%s", name, g_warp ? " (software)" : "");
    }
    return s;
}
