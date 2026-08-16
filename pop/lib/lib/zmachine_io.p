/* --- Z-machine input and output -----------------------------------------
 > File:            pop/lib/lib/zmachine_io.p
 > Purpose:         Pluggable screen and keyboard for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > The interpreter never calls -cucharout- itself.  It calls through the
 > variables below, so a front end -- a terminal, a VED window, a notebook
 > cell, an agent tool -- installs itself simply by dlocal-ing them for the
 > duration of a game.  That is Pop-11's own answer to dependency
 > injection, and it needs no interface machinery at all:
 >
 >     define play_in_a_notebook(story);
 >         dlocal zio_char = collect_into_the_cell;
 >         zm_play(story);
 >     enddefine;
 */
compile_mode :pop11 +strict;

section $-zmachine =>
        zio_char zio_read_line zio_read_char zio_status zio_upper
        zm_out zm_out_num zm_emit zm_window zm_upper_height
        zm_window_reset zm_upper_flush zm_mem_streams
    ;

;;; ZSCII output codes: 13 is newline, 32..126 are ASCII, and the rest are
;;; either the extended table (155..251) or not output at all.
define lconstant tty_char(c);
    lvars c;
    if c == 13 then
        cucharout(`\n`)
    elseif c fi_>= 32 and c fi_<= 126 then
        cucharout(c)
    elseif c == 0 then
        ;;; ZSCII 0 is "no character" -- silently ignored, per the spec
    else
        cucharout(`?`)
    endif
enddefine;

define lconstant tty_read_line() -> line;
    lvars c, n = 0, line;
    sysflush(popdevout);
    repeat
        charin() -> c;
        quitif(c == termin or c == `\n`);
        c;                              ;;; accumulate on the open stack
        n fi_+ 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

;;; The v3 status line is drawn by the interpreter, not the game: room
;;; name on the left, score and moves on the right.  A plain terminal has
;;; nowhere to put it, so by default it is simply not shown; a VED or
;;; curses front end overrides this.
define lconstant tty_read_char() -> c;
    lvars c;
    sysflush(popdevout);
    charin() -> c;
    if c == termin then 13 -> c
    elseif c == `\n` then 13 -> c
    endif
enddefine;

define lconstant tty_status(room, score, moves);
    lvars room, score, moves;
enddefine;

;;; From v4 the game draws its own status bar into an "upper window" that
;;; it splits off the top of the screen.  A plain stream has no such
;;; window, so by default that text is simply dropped -- printing it
;;; inline is what makes an unwindowed interpreter's transcript look
;;; scrambled.  A screen-addressable front end overrides this.
define lconstant tty_upper(text);
    lvars text;
enddefine;

vars procedure
    zio_char      = tty_char,           ;;; emit one ZSCII character
    zio_read_line = tty_read_line,      ;;; read one line of input
    zio_read_char = tty_read_char,      ;;; read a single keypress (v4+)
    zio_status    = tty_status,         ;;; redraw the v3 status line
    zio_upper     = tty_upper,          ;;; the v4+ upper window's contents
    ;

;;; Which window the game is currently printing to, and how many lines it
;;; asked to reserve at the top.
vars zm_window = 0, zm_upper_height = 0;

;;; Output stream 3 redirects printing into a table in the game's own
;;; memory, and while it is active NOTHING reaches the screen.  Games lean
;;; on this more than you would guess: Inform prints an object's name into
;;; a table purely to look at its first letter and decide between "a" and
;;; "an".  An interpreter that ignores the redirection prints every such
;;; name twice.  Streams can nest, so this is a stack.
vars zm_mem_streams = [];

lvars upper_chars = [], upper_n = 0;

define zm_window_reset();
    0 -> zm_window;
    0 -> zm_upper_height;
    [] -> upper_chars;
    0 -> upper_n;
    [] -> zm_mem_streams;
enddefine;

;;; Every character the machine prints comes through here, which is where
;;; the two windows are kept apart.
define zm_emit(c);
    lvars c, t, len;
    if zm_mem_streams /== [] then
        ;;; a memory stream swallows everything: the table's first word is
        ;;; a running count, and the characters follow it
        fast_front(zm_mem_streams) -> t;
        zm_word(t) -> len;
        c -> zm_byte(t fi_+ 2 fi_+ len);
        len fi_+ 1 -> zm_word(t);
    elseif zm_window == 0 then
        zio_char(c)
    else
        conspair(c, upper_chars) -> upper_chars;
        upper_n fi_+ 1 -> upper_n;
    endif
enddefine;

;;; Hand the upper window's text to the front end and start it afresh --
;;; done when the game switches back to the main window, which is when a
;;; status bar has just been drawn in full.
define zm_upper_flush();
    if upper_n fi_> 0 then
        zio_upper(consstring(destlist(rev(upper_chars))));
        [] -> upper_chars;
        0 -> upper_n;
    endif
enddefine;

;;; Convenience: a whole Pop-11 string, and a signed number.
define zm_out(s);
    lvars s, i;
    fast_for i from 1 to datalength(s) do
        zm_emit(fast_subscrs(i, s))
    endfor
enddefine;

define zm_out_num(n);
    lvars n;
    zm_out(n sys_>< nullstring)
enddefine;

endsection;
