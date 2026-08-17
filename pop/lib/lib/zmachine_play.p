/* --- Playing a story a turn at a time -----------------------------------
 > File:            pop/lib/lib/zmachine_play.p
 > Purpose:         Turn-by-turn sessions for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > zm_play runs a game until it ends, reading from the keyboard whenever it
 > wants a command.  A notebook cell, an agent's tool call and a web
 > request all want the opposite arrangement: give me one command's worth
 > of output and then GET OUT of my way until I call again.
 >
 > That inversion is exactly what a Pop-11 process is for.  The
 > interpreter runs inside one; when it asks for input the process
 > suspends, handing the turn's text back to whoever resumed it, and the
 > next call resumes it with the next command.  No threads, no re-entering
 > the interpreter, no replaying the game from the start:
 >
 >     zplay_start('cave.z3') =>
 >     ** THE POPLOG CAVE ... Cave Mouth ...
 >     zplay_turn('take lamp') =>
 >     ** Taken.
 >
 > (Poplog's process machinery is itself a nice thing to be standing on
 > here: the save/restore routines it needs were unimplemented stubs on
 > arm64 until earlier in the same week this file was written.)
 */
compile_mode :pop11 +strict;

uses zmachine;

section $-zmachine =>
        zplay_start zplay_turn zplay_playing zplay_story
    ;

vars
    zplay_proc  = false,        ;;; the process the interpreter runs in
    zplay_story = false,
    ;

lvars turn_chars = [], turn_n = 0;

;;; Everything the game prints this turn is collected rather than shown.
define lconstant collect(c);
    lvars c;
    conspair(if c == 13 then `\n` else c endif, turn_chars) -> turn_chars;
    turn_n fi_+ 1 -> turn_n;
enddefine;

;;; Asked for a command, the process steps aside instead of reading the
;;; keyboard.  Whatever the next zplay_turn passes in comes back as the
;;; result of the suspend.
define lconstant ask_caller() -> line;
    lvars line;
    suspend(0) -> line;
enddefine;

;;; The status bar a v4+ game draws is kept out of the transcript; a
;;; notebook shows the room in the prose anyway.
define lconstant swallow_upper(text);
    lvars text;
enddefine;

define lconstant take_turn() -> text;
    lvars text;
    [] -> turn_chars; 0 -> turn_n;
    consstring(destlist(rev(turn_chars))) -> text;
enddefine;

define lconstant session_body(story);
    lvars story;
    dlocal zio_char      = collect,
           zio_read_line = ask_caller,
           zio_upper     = swallow_upper,
           poplinemax    = false,
           poplinewidth  = false;
    zm_load_story(story);
    zm_reset();
    zm_run() -> ;
enddefine;

;;; Is there a game waiting for a command?
define zplay_playing();
    zplay_proc and isliveprocess(zplay_proc)
enddefine;

define lconstant harvest() -> text;
    lvars text;
    consstring(destlist(rev(turn_chars))) -> text;
    [] -> turn_chars; 0 -> turn_n;
enddefine;

;;; Load a story and run it up to its first prompt.
define zplay_start(story) -> text;
    lvars story, text;
    story -> zplay_story;
    [] -> turn_chars; 0 -> turn_n;
    consproc(story, 1, session_body) -> zplay_proc;
    runproc(0, zplay_proc);
    harvest() -> text;
enddefine;

;;; Send one command and return everything the game said in reply.
define zplay_turn(cmd) -> text;
    lvars cmd, text;
    unless zplay_playing() then
        'The game is over.  Start another with zplay_start.' -> text;
        return
    endunless;
    [] -> turn_chars; 0 -> turn_n;
    cmd;                            ;;; the command is the suspend's result
    runproc(1, zplay_proc);
    harvest() -> text;
enddefine;

endsection;
