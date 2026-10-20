/* Poplog <-> Dear ImGui glue (native Metal + Cocoa).  See imgui_backend.h.
 *
 * Compile as ObjC++ with ARC: clang++ -ObjC++ -fobjc-arc.  Links against
 * Metal, MetalKit, Cocoa, QuartzCore, GameController, Carbon.
 *
 * Drives Dear ImGui imperatively (the example in examples/example_apple_metal
 * is delegate-driven; here Poplog owns the loop) using an MTKView in manual
 * (paused) mode -- we fetch a render-pass descriptor + drawable per frame and
 * present it ourselves from pop_gfx_frame_end().
 *
 * The CANVAS is a retained display list (g_canvas): pop_gfx_draw_* append to it,
 * frame_begin replays it onto the background draw list every frame, and
 * pop_gfx_clear() wipes it -- so drawing persists like Xpw/rc_graphic.
 */
#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include <vector>
#include <string>
#include <cmath>
#include <cstdio>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"
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

/* --- window-close delegate -------------------------------------------- */
static bool g_closed = false;

@interface PopGfxWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation PopGfxWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; g_closed = true; return NO; }
@end

/* --- Metal-backed view ------------------------------------------------- *
 * A plain NSView whose backing layer is a CAMetalLayer that WE manage.  We
 * deliberately do NOT use MTKView: MTKView only advances/recycles its drawable
 * pool inside its own draw() cycle, which an externally-driven loop like ours
 * (Poplog owns the loop; the view is never asked to draw) never enters -- so
 * the pool drains and currentDrawable stalls on its ~1s timeout, which is the
 * animation "freeze".  A plain CAMetalLayer + nextDrawable recycles correctly
 * under fully manual control.  See NOTES-METAL-GRAPHICS-MACOS.md. */
@interface PopGfxMetalView : NSView
@end
@implementation PopGfxMetalView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
@end

/* --- backend state ----------------------------------------------------- */
static id<MTLDevice>            g_device   = nil;
static id<MTLCommandQueue>      g_queue    = nil;
static NSWindow                *g_window   = nil;
static NSView                  *g_view     = nil;   /* a PopGfxMetalView        */
static CAMetalLayer            *g_layer    = nil;   /* its backing layer        */
static id<CAMetalDrawable>      g_drawable = nil;   /* this frame's drawable    */
static PopGfxWindowDelegate    *g_delegate = nil;
static MTLRenderPassDescriptor *g_rpd      = nil;
static bool                     g_frame_active = false;

int pop_gfx_init(const char *title, int width, int height)
{
    @autoreleasepool {
        g_device = MTLCreateSystemDefaultDevice();
        if (g_device == nil)
            return 0;                                  /* no Metal-capable GPU  */
        g_queue = [g_device newCommandQueue];

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(0, 0,
                                  width  > 0 ? width  : 1200,
                                  height > 0 ? height : 720);
        g_window = [[NSWindow alloc] initWithContentRect:frame
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
            backing:NSBackingStoreBuffered defer:NO];
        [g_window setTitle:[NSString stringWithUTF8String:(title ? title : "Poplog")]];

        g_view = [[PopGfxMetalView alloc] initWithFrame:frame];
        g_view.wantsLayer = YES;                        /* -> CAMetalLayer       */
        g_layer = (CAMetalLayer *)g_view.layer;
        g_layer.device = g_device;
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.framebufferOnly = YES;
        g_window.contentView = g_view;

        g_delegate = [[PopGfxWindowDelegate alloc] init];
        g_window.delegate = g_delegate;

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGui::GetIO().IniFilename = NULL;             /* no imgui.ini for host */
        ImGui::StyleColorsDark();
        /* A font with CJK coverage, BEFORE the renderer init: ImGui's own
         * atlas is ASCII, so pop_gfx_draw_text() accepted UTF-8 and drew
         * nothing for it (imgui_font.cpp). */
        pop_gfx_font_init();
        ImGui_ImplMetal_Init(g_device);
        ImGui_ImplOSX_Init(g_view);

        [g_window center];
        [g_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp finishLaunching];                       /* run loop w/o NSApp run */
        g_closed = false;
        return 1;
    }
}

void pop_gfx_poll(void)
{
    @autoreleasepool {
        NSEvent *ev;
        while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                          untilDate:[NSDate distantPast]
                          inMode:NSDefaultRunLoopMode
                          dequeue:YES]) != nil) {
            [NSApp sendEvent:ev];
        }
    }
}

int pop_gfx_should_close(void) { return g_closed ? 1 : 0; }

int pop_gfx_frame_begin(void)
{
    pop_gfx_poll();
    @autoreleasepool {
        const CGSize sz = g_view.bounds.size;
        CGFloat scale = g_window.screen.backingScaleFactor;
        if (scale <= 0) scale = 1.0;
        g_layer.contentsScale = scale;
        g_layer.drawableSize  = CGSizeMake(sz.width * scale, sz.height * scale);

        id<CAMetalDrawable> drawable = [g_layer nextDrawable];
        if (drawable == nil)
            return 0;                                  /* no drawable this tick */
        g_drawable = drawable;                         /* held until present     */

        g_rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        g_rpd.colorAttachments[0].texture     = drawable.texture;
        g_rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        g_rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        g_rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.10, 0.10, 0.12, 1.0);

        ImGuiIO &io = ImGui::GetIO();
        io.DisplaySize = ImVec2((float)sz.width, (float)sz.height);
        io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);

        ImGui_ImplMetal_NewFrame(g_rpd);
        ImGui_ImplOSX_NewFrame(g_view);
        ImGui::NewFrame();
        canvas_replay();                               /* retained drawing      */
        g_frame_active = true;
    }
    return 1;
}

void pop_gfx_frame_end(void)
{
    if (!g_frame_active)
        return;
    g_frame_active = false;

    @autoreleasepool {
        ImGui::Render();
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLRenderCommandEncoder> enc =
            [cb renderCommandEncoderWithDescriptor:g_rpd];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
        [enc endEncoding];
        if (g_drawable != nil)
            [cb presentDrawable:g_drawable];
        [cb commit];
        g_rpd = nil;
        g_drawable = nil;
    }
}

void pop_gfx_shutdown(void)
{
    @autoreleasepool {
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplOSX_Shutdown();
        ImGui::DestroyContext();
        [g_window orderOut:nil];
        g_window.delegate = nil;
        g_drawable = nil; g_layer = nil;
        g_window = nil; g_view = nil; g_delegate = nil;
        g_queue = nil; g_device = nil;
        g_canvas.clear();
    }
}

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
    static char s[192] = {0};
    if (s[0] == '\0') {
        const char *dev = g_device ? [[g_device name] UTF8String] : "unknown GPU";
        snprintf(s, sizeof s, "Metal (CAMetalLayer) - %s", dev ? dev : "unknown GPU");
    }
    return s;
}
