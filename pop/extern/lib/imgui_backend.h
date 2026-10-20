/* Poplog <-> Dear ImGui glue: a small extern "C" surface (pop_gfx_*) over a
 * native Metal + Cocoa Dear ImGui backend, for the experimental macOS graphics
 * path (configure --experimental-gfx).  Poplog's FFI calls C; the implementation
 * (imgui_backend.mm) is ObjC++ and talks to ImGui's C++ API directly -- so no
 * cimgui, no GLFW/SDL.  See PORTING-ARM64-M-SILICON-OSX.md sec. 6.
 *
 * Two surfaces, matching how Poplog's graphics actually behave:
 *
 *  - CANVAS  (retained): the pop_gfx_draw_* / fill_* calls append to a retained
 *    display list that the backend replays every frame -- draw once and it
 *    persists, pop_gfx_clear() wipes it.  This mirrors Xpw/rc_graphic semantics
 *    (XpwDrawLine ... XpwClearWindow), so retargeting rc_graphic is ~1:1.
 *
 *  - PANELS  (immediate): the pop_gfx_begin/button/... calls are issued between
 *    frame_begin and frame_end each tick.  Widgets return their result inline
 *    (pop_gfx_button -> 1 on click), so UI logic runs via forward Pop->C calls
 *    without the reverse C->Pop callback trampoline.
 *
 * Per tick Poplog calls: poll -> frame_begin -> [panels] -> frame_end.
 */
#ifndef POP_IMGUI_BACKEND_H
#define POP_IMGUI_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- lifecycle (call on the main thread) ------------------------------- */
int  pop_gfx_init(const char *title, int width, int height); /* 1 ok, 0 fail */
void pop_gfx_shutdown(void);
int  pop_gfx_should_close(void);   /* 1 once the window has been closed      */

/* --- frame ------------------------------------------------------------- */
/* frame_begin returns 1 if a frame is ready (then draw + call frame_end), or
 * 0 if no drawable is available this tick (skip drawing and frame_end).  It
 * replays the retained canvas, so persistent drawing shows every frame. */
int  pop_gfx_frame_begin(void);
void pop_gfx_frame_end(void);
void pop_gfx_poll(void);           /* pump pending OS events (non-blocking)  */

/* --- retained canvas (screen-space pixels; persists until clear) -------- */
void     pop_gfx_clear(void);                     /* wipe the canvas (XpwClearWindow) */
int      pop_gfx_mark(void);                      /* canvas length, for rewind        */
void     pop_gfx_rewind(int mark);                /* truncate canvas back to a mark   */
uint32_t pop_gfx_rgba(int r, int g, int b, int a);
void pop_gfx_draw_point(float x, float y, uint32_t rgba);
void pop_gfx_draw_line(float x0, float y0, float x1, float y1, uint32_t rgba, float thickness);
void pop_gfx_draw_rect(float x0, float y0, float x1, float y1, uint32_t rgba, float thickness);
void pop_gfx_fill_rect(float x0, float y0, float x1, float y1, uint32_t rgba);
void pop_gfx_draw_circle(float cx, float cy, float r, uint32_t rgba, float thickness);
void pop_gfx_fill_circle(float cx, float cy, float r, uint32_t rgba);
void pop_gfx_draw_arc(float cx, float cy, float r, float start_deg, float end_deg, uint32_t rgba, float thickness);
void pop_gfx_draw_text(float x, float y, uint32_t rgba, const char *text);

/* --- immediate panels (ImGui windows + widgets) ------------------------ */
int  pop_gfx_begin(const char *title); /* 1 if visible; ALWAYS call end()    */
void pop_gfx_end(void);
void pop_gfx_label(const char *text);
int  pop_gfx_button(const char *label);          /* 1 on click               */
int  pop_gfx_checkbox(const char *label, int value); /* returns new value     */

/* --- input ------------------------------------------------------------- */
float pop_gfx_mouse_x(void);
float pop_gfx_mouse_y(void);
int   pop_gfx_mouse_down(int button);  /* 0=left 1=right 2=middle; 1 if down */

/* --- fonts -------------------------------------------------------------- */
/* Called by pop_gfx_init between ImGui::CreateContext() and the renderer
 * init.  Loads a font with CJK coverage so pop_gfx_draw_text can draw the
 * UTF-8 it already accepts; returns 1 if a font file was found, 0 if it fell
 * back to ImGui's ASCII-only default.  pop_gfx_font_path reports which file
 * (NULL when the default was used).  See imgui_font.cpp. */
int         pop_gfx_font_init(void);
const char *pop_gfx_font_path(void);
float       pop_gfx_font_size(void);

/* --- introspection / stats --------------------------------------------- */
float       pop_gfx_fps(void);   /* smoothed frames/sec (ImGui's running avg) */
const char *pop_gfx_spec(void);  /* one-line backend + renderer/GPU spec      */

#ifdef __cplusplus
}
#endif

#endif /* POP_IMGUI_BACKEND_H */
