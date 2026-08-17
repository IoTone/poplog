/* --- Z-machine save and restore (Quetzal) -------------------------------
 > File:            pop/lib/lib/zmachine_save.p
 > Purpose:         Standard-format saved games for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Everything that changes while a game is played lives in four places:
 > dynamic memory, the evaluation stack, the chain of call frames, and the
 > program counter.  Saving is writing those four down.
 >
 > The format is Quetzal, the standard one, so a game saved here can be
 > restored in Frotz or Zoom and vice versa.  Quetzal is IFF: a FORM
 > wrapper of type IFZS containing typed chunks --
 >
 >     IFhd    which story this is (release, serial, checksum) and the PC
 >     CMem    dynamic memory, compressed against the original file
 >     Stks    the call frames, oldest first, each with its slice of stack
 >
 > The compression is the neat part.  Dynamic memory usually differs from
 > the published file in only a few hundred places, so CMem stores the XOR
 > of the two and writes runs of zeros as a zero byte plus a count -- a
 > 50K game routinely saves in two or three kilobytes.
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_core;

section $-zmachine =>
        zm_save_file zm_save_state zm_restore_state
    ;

;;; Where a save goes when the game does not say (v3 games never do).
vars zm_save_file = false;

define lconstant save_path();
    if zm_save_file then zm_save_file else zm_story_file sys_>< '.qzl' endif
enddefine;

;;; ---- writing -----------------------------------------------------------

;;; Bytes accumulate in a list and become a string at the end; a save runs
;;; once per turn at most, so nothing here needs to be clever.
lvars out_acc = [], out_n = 0;

define lconstant put(b);
    lvars b;
    conspair(b fi_&& 16:FF, out_acc) -> out_acc;
    out_n fi_+ 1 -> out_n;
enddefine;

define lconstant put16(v); lvars v; put(v fi_>> 8); put(v) enddefine;
define lconstant put24(v); lvars v; put(v fi_>> 16); put(v fi_>> 8); put(v) enddefine;
define lconstant put32(v); lvars v; put16(v fi_>> 16); put16(v fi_&& 16:FFFF) enddefine;

define lconstant put_str(s);
    lvars s, i;
    fast_for i from 1 to datalength(s) do put(fast_subscrs(i, s)) endfor
enddefine;

;;; The frames, oldest first -- which is the order Quetzal wants and the
;;; reverse of how we hold them.
define lconstant frames_oldest_first() -> l;
    lvars l = rev(conspair(zm_frame, zm_frames));
enddefine;

;;; dynamic memory XORed against the published file, with runs of
;;; unchanged bytes written as a zero and a count
define lconstant cmem_bytes() -> s;
    lvars i, x, zeros = 0, s, saved_acc = out_acc, saved_n = out_n;
    [] -> out_acc; 0 -> out_n;
    fast_for i from 0 to zm_static_base fi_- 1 do
        (zm_byte(i) fi_|| fast_subscrs(i fi_+ 1, zm_orig))
            fi_- (zm_byte(i) fi_&& fast_subscrs(i fi_+ 1, zm_orig)) -> x;
        if x == 0 then
            zeros fi_+ 1 -> zeros
        else
            ;;; a run of unchanged bytes: 0, then the length less one,
            ;;; repeated for runs longer than 256
            until zeros == 0 do
                put(0);
                if zeros fi_> 256 then put(255); zeros fi_- 256 -> zeros
                else put(zeros fi_- 1); 0 -> zeros
                endif
            enduntil;
            put(x)
        endif
    endfor;
    ;;; trailing unchanged bytes need not be written at all
    consstring(destlist(rev(out_acc))) -> s;
    saved_acc -> out_acc; saved_n -> out_n;
enddefine;

define lconstant stks_bytes() -> s;
    lvars f, frames = frames_oldest_first(), i, j, nxt, top,
          s, saved_acc = out_acc, saved_n = out_n;
    [] -> out_acc; 0 -> out_n;
    1 -> i;
    for f in frames do
        ;;; Quetzal opens with a DUMMY frame standing for the interpreter's
        ;;; state before the first routine was called: every field zero
        ;;; except its share of the stack.  Ours is the initial frame, and
        ;;; writing its "no result variable" as the discard-result flag
        ;;; (bit 4) is enough to make Frotz reject the whole file.
        ;;; each frame's slice of the shared stack runs from its own base
        ;;; up to the base of the frame it called (or the top, if it is
        ;;; the one running)
        if i fi_< listlength(frames) then
            zf_eval_base(frames(i fi_+ 1)) -> top
        else
            zm_sp -> top
        endif;
        put24(zf_return_pc(f));
        ;;; low four bits: how many locals.  Bit 4: the result is thrown
        ;;; away (a call_n), which Quetzal records instead of a variable.
        if i == 1 then
            put(0); put(0)                  ;;; the dummy frame
        else
            put((if zf_store_var(f) then 0 else 16:10 endif)
                    fi_|| (zf_nlocals(f) fi_&& 16:0F));
            put(if zf_store_var(f) then zf_store_var(f) else 0 endif)
        endif;
        ;;; which arguments were supplied, as a bit per argument
        put((1 fi_<< zf_nargs(f)) fi_- 1);
        put16(top fi_- zf_eval_base(f));
        fast_for j from 1 to zf_nlocals(f) do
            put16(subscrintvec(j, zf_locals(f)))
        endfor;
        fast_for j from zf_eval_base(f) fi_+ 1 to top do
            put16(subscrintvec(j, zm_stack))
        endfor;
        i fi_+ 1 -> i;
    endfor;
    consstring(destlist(rev(out_acc))) -> s;
    saved_acc -> out_acc; saved_n -> out_n;
enddefine;

;;; An IFF chunk: four-character type, length, data, and a pad byte when
;;; the length is odd.
define lconstant put_chunk(id, data);
    lvars id, data;
    put_str(id);
    put32(datalength(data));
    put_str(data);
    if datalength(data) fi_&& 1 == 1 then put(0) endif
enddefine;

define zm_save_state() -> ok;
    lvars ok = false, dev, body, ifhd, i;

    [] -> out_acc; 0 -> out_n;

    ;;; IFhd: which story, and where it was
    put16(zm_release);
    fast_for i from 1 to 6 do put(fast_subscrs(i, zm_serial)) endfor;
    put16(zm_checksum);
    put24(zm_pc);
    consstring(destlist(rev(out_acc))) -> ifhd;

    [] -> out_acc; 0 -> out_n;
    put_chunk('IFhd', ifhd);
    put_chunk('CMem', cmem_bytes());
    put_chunk('Stks', stks_bytes());
    consstring(destlist(rev(out_acc))) -> body;

    [] -> out_acc; 0 -> out_n;
    put_str('FORM');
    put32(datalength(body) fi_+ 4);         ;;; the type that follows counts
    put_str('IFZS');
    put_str(body);

    if (syscreate(save_path(), 1, true) ->> dev) then
        lvars whole = consstring(destlist(rev(out_acc)));
        syswrite(dev, whole, datalength(whole));
        sysclose(dev);
        true -> ok;
    endif;
    [] -> out_acc; 0 -> out_n;
enddefine;

;;; ---- reading -----------------------------------------------------------

define zm_restore_state() -> ok;
    lvars ok = false, dev, len, s, pos, end, id, clen,
          ifhd = false, cmem = false, umem = false, stks = false;

    define lconstant at(i);         ;;; a byte of the file, 1-based
        lvars i;
        fast_subscrs(i, s)
    enddefine;

    define lconstant word_at(i);
        lvars i;
        (at(i) fi_<< 8) fi_|| at(i fi_+ 1)
    enddefine;

    define lconstant long_at(i);
        lvars i;
        (word_at(i) fi_<< 16) fi_|| word_at(i fi_+ 2)
    enddefine;

    returnunless(readable(save_path()) ->> dev);
    sysclose(dev);
    sysfilesize(save_path()) -> len;
    returnif(len fi_< 24);
    sysopen(save_path(), 0, true) -> dev;
    inits(len) -> s;
    sysread(dev, s, len) -> ;
    sysclose(dev);

    ;;; an IFF FORM of type IFZS, and nothing else
    returnunless(substring(1, 4, s) = 'FORM' and substring(9, 4, s) = 'IFZS');

    ;;; walk the chunks, remembering the ones we understand
    13 -> pos;
    len fi_+ 1 -> end;
    while pos fi_+ 8 fi_<= end do
        substring(pos, 4, s) -> id;
        long_at(pos fi_+ 4) -> clen;
        quitif(pos fi_+ 8 fi_+ clen fi_> end);
        if id = 'IFhd' then pos fi_+ 8 -> ifhd
        elseif id = 'CMem' then conspair(pos fi_+ 8, clen) -> cmem
        elseif id = 'UMem' then conspair(pos fi_+ 8, clen) -> umem
        elseif id = 'Stks' then conspair(pos fi_+ 8, clen) -> stks
        endif;
        pos fi_+ 8 fi_+ clen fi_+ (clen fi_&& 1) -> pos;
    endwhile;
    returnunless(ifhd and stks and (cmem or umem));

    ;;; refuse a save belonging to a different story
    returnunless(word_at(ifhd) == zm_release);
    returnunless(substring(ifhd fi_+ 2, 6, s) = zm_serial);
    returnunless(word_at(ifhd fi_+ 8) == zm_checksum);

    ;;; ---- dynamic memory ----
    zm_restore_dynamic();               ;;; start from the published bytes
    if cmem then
        lvars p = fast_front(cmem), stop = p fi_+ fast_back(cmem), addr = 0, b;
        while p fi_< stop and addr fi_< zm_static_base do
            at(p) -> b; p fi_+ 1 -> p;
            if b == 0 then
                ;;; a run of bytes that match the original
                addr fi_+ at(p) fi_+ 1 -> addr; p fi_+ 1 -> p
            else
                ;;; XOR against the original gives the byte back
                ((zm_byte(addr) fi_|| b) fi_- (zm_byte(addr) fi_&& b))
                    -> zm_byte(addr);
                addr fi_+ 1 -> addr
            endif
        endwhile
    else
        lvars p = fast_front(umem), i, n = fast_back(umem);
        fast_for i from 0 to min(n, zm_static_base) fi_- 1 do
            at(p fi_+ i) -> zm_byte(i)
        endfor
    endif;

    ;;; ---- the PC ----
    long_at(ifhd fi_+ 9) fi_&& 16:FFFFFF -> zm_pc;
    ;;; long_at read one byte too many; the PC is only three bytes
    ((at(ifhd fi_+ 10) fi_<< 16) fi_|| (at(ifhd fi_+ 11) fi_<< 8)
        fi_|| at(ifhd fi_+ 12)) -> zm_pc;

    ;;; ---- frames and stack ----
    lvars p = fast_front(stks), stop = p fi_+ fast_back(stks),
          frames = [], fr, nloc, flags, sv, nst, j, locals;
    0 -> zm_sp;
    while p fi_+ 8 fi_<= stop do
        ((at(p) fi_<< 16) fi_|| (at(p fi_+ 1) fi_<< 8) fi_|| at(p fi_+ 2)) -> j;
        at(p fi_+ 3) -> flags;
        at(p fi_+ 4) -> sv;
        at(p fi_+ 6) fi_<< 8 fi_|| at(p fi_+ 7) -> nst;
        flags fi_&& 16:0F -> nloc;
        p fi_+ 8 -> p;
        initintvec(15) -> locals;
        conszframe(j,
                   if (flags fi_&& 16:10) /== 0 then false else sv endif,
                   locals, 0, zm_sp, nloc) -> fr;
        ;;; how many arguments were supplied is a bit per argument
        lvars a = at(p fi_- 3), cnt = 0;
        while (a fi_&& 1) == 1 do cnt fi_+ 1 -> cnt; a fi_>> 1 -> a endwhile;
        cnt -> zf_nargs(fr);
        fast_for j from 1 to nloc do
            word_at(p) -> subscrintvec(j, locals); p fi_+ 2 -> p
        endfor;
        fast_for j from 1 to nst do
            zm_sp fi_+ 1 -> zm_sp;
            word_at(p) -> subscrintvec(zm_sp, zm_stack);
            p fi_+ 2 -> p
        endfor;
        conspair(fr, frames) -> frames;
    endwhile;
    returnif(frames == []);
    ;;; frames were read oldest first, so the head is now the innermost
    fast_destpair(frames) -> zm_frames -> zm_frame;

    true -> ok;
enddefine;

endsection;
