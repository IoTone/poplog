/* --- Apple M-silicon Poplog. Distributed under the Free Poplog licence. ---
 * File:    pop/lib/lib/popgfx.p
 * Purpose: Pop-11 binding for the native graphics backend (Dear ImGui +
 *          Metal, macOS).  The C surface (pop_gfx_*, see
 *          pop/extern/lib/imgui_backend.h) is linked into the Poplog
 *          executable when built with GFX_CONF=imgui (configure
 *          --experimental-gfx), so the symbols resolve from the image.
 *
 * Retained canvas: gfx_line etc. persist until gfx_clear(); call
 * gfx_step() once per frame (it pumps events, redraws, and returns false
 * once the window is closed).
 */

section;

exload popgfx []
(language C)
    lconstant
        pop_gfx_init(title, w, h)                   :int,
        pop_gfx_shutdown(),
        pop_gfx_should_close()                      :int,
        pop_gfx_frame_begin()                       :int,
        pop_gfx_frame_end(),
        pop_gfx_poll(),
        pop_gfx_clear(),
        pop_gfx_mark()                              :int,
        pop_gfx_rewind(m),
        pop_gfx_rgba(r, g, b, a)                    :uint,
        ;;; The geometry args are C `float` (ANSI prototypes), but Poplog
        ;;; passes (d)decimals as double by DEFAULT (REF * EXTERNAL 5.2) --
        ;;; so each float arg needs the <SF> flag to be passed single, or
        ;;; the callee reads a 32-bit float out of a 64-bit double and the
        ;;; coordinates come through corrupted.  `c` is the packed RGBA int.
        pop_gfx_draw_point(x<SF>, y<SF>, c),
        pop_gfx_draw_line(x0<SF>, y0<SF>, x1<SF>, y1<SF>, c, t<SF>),
        pop_gfx_draw_rect(x0<SF>, y0<SF>, x1<SF>, y1<SF>, c, t<SF>),
        pop_gfx_fill_rect(x0<SF>, y0<SF>, x1<SF>, y1<SF>, c),
        pop_gfx_draw_circle(cx<SF>, cy<SF>, r<SF>, c, t<SF>),
        pop_gfx_fill_circle(cx<SF>, cy<SF>, r<SF>, c),
        pop_gfx_draw_arc(cx<SF>, cy<SF>, r<SF>, a0<SF>, a1<SF>, c, t<SF>),
        pop_gfx_draw_text(x<SF>, y<SF>, c, s),
        pop_gfx_mouse_x()                           :float,
        pop_gfx_mouse_y()                           :float,
        pop_gfx_mouse_down(b)                       :int,
        pop_gfx_fps()                               :float,
        pop_gfx_spec()                              :exptr,
        pop_gfx_font_path()                         :exptr,
    ;
endexload;

;;; C float params need single-float pop values
define lconstant f(x); number_coerce(x, 0.0s0) enddefine;

;;; Which font file the atlas loaded, or false for ImGui's ASCII-only
;;; default -- i.e. whether gfx_text can draw anything but Latin.
define gfx_font() -> path;
    lvars p = exacc pop_gfx_font_path();
    if p == 0 then false else exacc_ntstring(p) endif -> path;
enddefine;

define gfx_init(title, w, h);
    lvars ok = exacc pop_gfx_init(title, w, h) /== 0;
    ;;; Say it once, here, rather than let it be discovered a glyph at a
    ;;; time: gfx_text takes UTF-8, but a glyph the atlas does not hold
    ;;; draws as nothing at all.  pop_gfx_font_init loads a CJK-capable
    ;;; font when it can find one (pop/extern/lib/imgui_font.cpp).
    if ok and gfx_font() == false then
        printf(';;; popgfx: no font file found -- text is ASCII only.\n');
        printf(';;; popgfx: run tools/fetch-gfx-font.sh, or set POPLOG_GFX_FONT.\n');
    endif;
    ok
enddefine;

define gfx_shutdown();    exacc pop_gfx_shutdown()       enddefine;
define gfx_clear();       exacc pop_gfx_clear()          enddefine;

define gfx_rgb(r, g, b);  exacc pop_gfx_rgba(r, g, b, 255) enddefine;

define gfx_point(x, y, c);
    exacc pop_gfx_draw_point(f(x), f(y), c)
enddefine;

define gfx_line(x0, y0, x1, y1, c, t);
    exacc pop_gfx_draw_line(f(x0), f(y0), f(x1), f(y1), c, f(t))
enddefine;

define gfx_rect(x0, y0, x1, y1, c, t);
    exacc pop_gfx_draw_rect(f(x0), f(y0), f(x1), f(y1), c, f(t))
enddefine;

define gfx_fill_rect(x0, y0, x1, y1, c);
    exacc pop_gfx_fill_rect(f(x0), f(y0), f(x1), f(y1), c)
enddefine;

define gfx_circle(cx, cy, r, c, t);
    exacc pop_gfx_draw_circle(f(cx), f(cy), f(r), c, f(t))
enddefine;

define gfx_fill_circle(cx, cy, r, c);
    exacc pop_gfx_fill_circle(f(cx), f(cy), f(r), c)
enddefine;

define gfx_text(x, y, c, s);
    exacc pop_gfx_draw_text(f(x), f(y), c, s)
enddefine;

define gfx_mouse() /* -> (x, y) */;
    exacc pop_gfx_mouse_x(), exacc pop_gfx_mouse_y()
enddefine;

define gfx_mouse_down(b);
    exacc pop_gfx_mouse_down(b) /== 0
enddefine;

;;; canvas mark/rewind: undo drawing added since the mark
define gfx_mark();        exacc pop_gfx_mark()    enddefine;
define gfx_rewind(m);     exacc pop_gfx_rewind(m) enddefine;

;;; stats / config introspection (for HUD badges etc.)
define gfx_fps();   exacc pop_gfx_fps() enddefine;          ;;; smoothed frames/sec
define gfx_spec();  exacc_ntstring(exacc pop_gfx_spec()) enddefine;  ;;; backend+GPU


;;; one frame: pump + draw; false once the window has been closed
define gfx_step();
    returnif(exacc pop_gfx_should_close() /== 0)(false);
    if exacc pop_gfx_frame_begin() /== 0 then
        exacc pop_gfx_frame_end()
    endif;
    true
enddefine;

;;; run the window loop for n frames (or until closed)
define gfx_run(n);
    repeat n times
        quitunless(gfx_step());
        syssleep(2)                  ;;; ~50 fps (centiseconds)
    endrepeat
enddefine;

endsection;
