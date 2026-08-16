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
        zio_char zio_read_line zio_status
        zm_out zm_out_num
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
define lconstant tty_status(room, score, moves);
    lvars room, score, moves;
enddefine;

vars procedure
    zio_char      = tty_char,           ;;; emit one ZSCII character
    zio_read_line = tty_read_line,      ;;; read one line of input
    zio_status    = tty_status,         ;;; redraw the v3 status line
    ;

;;; Convenience: a whole Pop-11 string, and a signed number.
define zm_out(s);
    lvars s, i;
    fast_for i from 1 to datalength(s) do
        zio_char(fast_subscrs(i, s))
    endfor
enddefine;

define zm_out_num(n);
    lvars n;
    zm_out(n sys_>< nullstring)
enddefine;

endsection;
