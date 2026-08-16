/* --- Z-machine save and restore -----------------------------------------
 > File:            pop/lib/lib/zmachine_save.p
 > Purpose:         Saving and restoring a game for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Everything that changes while a game is played lives in four places:
 > dynamic memory, the evaluation stack, the chain of call frames, and the
 > program counter.  Saving is writing those four down; restoring is
 > putting them back.  Static and high memory never change, so a save file
 > does not carry them -- it carries enough of the story's identity
 > (release, serial, checksum) to refuse a save that belongs to a different
 > game.
 >
 > The format here is our own and deliberately simple.  Milestone M5
 > replaces it with Quetzal, the standard format, so that saves can be
 > exchanged with other interpreters; nothing above this file changes when
 > that happens.
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_core;

section $-zmachine =>
        zm_save_file zm_save_state zm_restore_state
    ;

lconstant MAGIC = 'POPZSAV1';

;;; Where a save goes when the game does not say (v3 games never do).
vars zm_save_file = false;

define lconstant save_path();
    if zm_save_file then
        zm_save_file
    else
        zm_story_file sys_>< '.sav'
    endif
enddefine;

;;; ---- writing -----------------------------------------------------------

define zm_save_state() -> ok;
    lvars ok = false, acc = [], n = 0, dev, s, f, i, frames, path = save_path();

    define lconstant put(b);
        lvars b;
        conspair(b fi_&& 16:FF, acc) -> acc;
        n fi_+ 1 -> n;
    enddefine;

    define lconstant put16(v);
        lvars v;
        put((v fi_>> 8) fi_&& 16:FF); put(v fi_&& 16:FF);
    enddefine;

    define lconstant put32(v);
        lvars v;
        put16((v fi_>> 16) fi_&& 16:FFFF); put16(v fi_&& 16:FFFF);
    enddefine;

    define lconstant put_frame(fr);
        lvars fr, j;
        put32(zf_return_pc(fr));
        ;;; store_var is false for a call whose result is discarded
        put16(if zf_store_var(fr) then zf_store_var(fr) else 16:FFFF endif);
        put16(zf_nargs(fr));
        put16(zf_eval_base(fr));
        fast_for j from 1 to 15 do put16(subscrintvec(j, zf_locals(fr))) endfor;
    enddefine;

    ;;; identity, so a save cannot be restored into the wrong story
    fast_for i from 1 to datalength(MAGIC) do put(fast_subscrs(i, MAGIC)) endfor;
    put16(zm_release);
    put16(zm_checksum);
    put32(zm_pc);
    put16(zm_sp);
    put32(zm_static_base);

    conspair(zm_frame, zm_frames) -> frames;
    put16(listlength(frames));

    ;;; dynamic memory, the stack, then the frames innermost first
    fast_for i from 0 to zm_static_base fi_- 1 do put(zm_byte(i)) endfor;
    fast_for i from 1 to zm_sp do put16(subscrintvec(i, zm_stack)) endfor;
    for f in frames do put_frame(f) endfor;

    consstring(destlist(rev(acc))) -> s;

    if (syscreate(path, 1, true) ->> dev) then
        syswrite(dev, s, datalength(s));
        sysclose(dev);
        true -> ok;
    endif;
enddefine;

;;; ---- reading -----------------------------------------------------------

define zm_restore_state() -> ok;
    lvars ok = false, dev, len, s, pos = 1, i, nframes, dynsize, frames = [],
          path = save_path(), fr, locals, j, sv;

    define lconstant get();
        lvars b = fast_subscrs(pos, s);
        pos fi_+ 1 -> pos;
        b
    enddefine;

    define lconstant get16();
        lvars hi = get();
        (hi fi_<< 8) fi_|| get()
    enddefine;

    define lconstant get32();
        lvars hi = get16();
        (hi fi_<< 16) fi_|| get16()
    enddefine;

    returnunless(readable(path) ->> dev);
    sysclose(dev);
    sysfilesize(path) -> len;
    returnif(len fi_< 24);
    sysopen(path, 0, true) -> dev;
    inits(len) -> s;
    sysread(dev, s, len) -> ;
    sysclose(dev);

    ;;; refuse anything that is not one of our saves for THIS story
    returnunless(datalength(s) fi_> datalength(MAGIC)
                 and substring(1, datalength(MAGIC), s) = MAGIC);
    datalength(MAGIC) fi_+ 1 -> pos;
    returnunless(get16() == zm_release);
    returnunless(get16() == zm_checksum);

    ;;; Nothing is disturbed until every check above has passed, so a
    ;;; failed restore leaves the game exactly as it was.
    get32() -> zm_pc;
    get16() -> zm_sp;
    get32() -> dynsize;
    returnunless(dynsize == zm_static_base);
    get16() -> nframes;

    fast_for i from 0 to dynsize fi_- 1 do get() -> zm_byte(i) endfor;
    fast_for i from 1 to zm_sp do get16() -> subscrintvec(i, zm_stack) endfor;

    fast_for i from 1 to nframes do
        get32() -> j;                       ;;; return pc
        get16() -> sv;                      ;;; store variable, or none
        initintvec(15) -> locals;
        conszframe(j, if sv == 16:FFFF then false else sv endif,
                   locals, 0, 0) -> fr;
        get16() -> zf_nargs(fr);
        get16() -> zf_eval_base(fr);
        fast_for j from 1 to 15 do get16() -> subscrintvec(j, locals) endfor;
        conspair(fr, frames) -> frames;
    endfor;
    rev(frames) -> frames;                  ;;; innermost first again
    fast_destpair(frames) -> zm_frames -> zm_frame;

    true -> ok;
enddefine;

endsection;
