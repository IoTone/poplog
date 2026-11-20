;;; gfx-test.p -- draw through LIB POPGFX from Pop-11 and capture the frame.
;;;
;;; Needs a basepop11 built with ./configure --experimental-graphics.  The
;;; output file is named by the environment variable GFX_TEST_OUT.  With
;;; POP_GFX_HEADLESS set no window appears, and with POP_GFX_RENDERER=warp
;;; no GPU is needed, so tools/validate-cygwin.sh can run this anywhere.
;;;
;;; The scene is the one pop/extern/lib/imgui_headless.cpp draws from C, so
;;; the two images can be compared: any difference is in how Pop passes the
;;; arguments (single floats, six and seven to a call), not in the renderer.

uses popgfx;

exload gfx_test []
(language C)
    lconstant
        pop_gfx_render_to_ppm(path) :int,
        ;;; LIB POPGFX has no arc; seven arguments, six of them single floats
        pop_gfx_draw_arc(cx<SF>, cy<SF>, r<SF>, a0<SF>, a1<SF>, c, t<SF>),
    ;
endexload;

unless gfx_init('Poplog on Windows -- gfx-test', 800, 520) then
    printf('GFX-INIT-FAILED\n');
    sysexit();
endunless;

vars white = gfx_rgb(255, 255, 255),
     green = gfx_rgb( 80, 220, 120),
     blue  = gfx_rgb(120, 160, 255),
     amber = gfx_rgb(255, 190,  60);

gfx_clear();
gfx_text(60, 24, white, 'Poplog on Windows: drawn from Pop-11 through LIB POPGFX');
gfx_rect(60, 60, 740, 440, white, 1.0);
gfx_line(60, 60, 740, 440, green, 3.0);
gfx_line(60, 440, 740, 60, blue, 3.0);
gfx_circle(400, 250, 120, amber, 2.0);
gfx_fill_circle(400, 250, 6, amber);
exacc pop_gfx_draw_arc(400.0s0, 250.0s0, 160.0s0, 200.0s0, 340.0s0, white, 2.0s0);
gfx_text(60, 470, white, '日本語 ひらがな カタカナ 1234');

;;; a few live frames first: the message pump and the swap chain
repeat 5 times gfx_step() -> endrepeat;

printf(gfx_spec(), 'SPEC %p\n');
printf(gfx_font(), 'FONT %p\n');
printf(exacc pop_gfx_render_to_ppm(systranslate('GFX_TEST_OUT')), 'RENDERED %p\n');
gfx_shutdown();
printf('GFX-TEST-DONE\n');
