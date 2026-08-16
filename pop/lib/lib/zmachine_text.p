/* --- Z-machine text (ZSCII) ---------------------------------------------
 > File:            pop/lib/lib/zmachine_text.p
 > Purpose:         ZSCII decoding for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Infocom had to fit a novel into 128K, so text is packed three 5-bit
 > "z-characters" to a 16-bit word, with the top bit marking the last word
 > of a string.  Those 5 bits address one of three 26-letter alphabets,
 > with a handful of values reserved for shifting between them, for
 > abbreviations (a built-in dictionary of common phrases), and for an
 > escape that spells out an arbitrary character in ten bits.
 >
 > Decoding is therefore a small state machine over a stream of z-chars,
 > which is what this file is.  Two entry points:
 >
 >     zm_text_out(addr, emit) -> next_addr     stream to a procedure
 >     zm_text(addr) -> string                  collect into a string
 >
 > The streaming form is the primitive because the interpreter wants to
 > send characters straight to the screen, not build strings it throws away.
 */
compile_mode :pop11 +strict;

uses zmachine_mem;

section $-zmachine =>
        zm_text_out zm_text zm_abbrev
    ;

;;; The alphabets, indexed by (z-char - 6) + 1 for Pop-11's 1-based strings.
;;; A2's first slot is the ten-bit escape and never reaches a lookup; its
;;; second is newline.  (v1 ordered A2 differently; we do v3 and up.)
lconstant
    ALPHABETS = {%
        'abcdefghijklmnopqrstuvwxyz',
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
        '\s\n0123456789.,!?_#\'"/\\-:()',
    %};

;;; Abbreviation n lives at a WORD address stored in the abbreviations
;;; table; word addresses are simply doubled to get a byte address.
define zm_abbrev(n);
    lvars n;
    zm_word(zm_abbrev_table fi_+ (n fi_* 2)) fi_* 2
enddefine;

;;; Pull the z-chars of the string starting at addr.
;;;
;;; Each word holds three of them, most significant first, and the top bit
;;; says "last word".  The values are pushed on the open stack as they are
;;; unpacked and -conslist- gathers them at the end -- the stack is right
;;; there, so no intermediate structure is built or grown.
define lconstant zchars_of(addr) -> (zl, next);
    lvars addr, w, n = 0, zl, next;
    repeat
        zm_word(addr) -> w;
        addr fi_+ 2 -> addr;
        (w fi_>> 10) fi_&& 2:11111;
        (w fi_>>  5) fi_&& 2:11111;
        (w           fi_&& 2:11111);
        n fi_+ 3 -> n;
        quitif((w fi_&& 16:8000) /== 0);
    endrepeat;
    conslist(n) -> zl;
    addr -> next;
enddefine;

;;; Decode the string at addr, sending each ZSCII character code to -emit-.
;;; Returns the address of whatever follows the string.
define zm_text_out(addr, procedure emit) -> next;
    lvars   addr, next, zl, z,
            alpha  = 0,         ;;; which alphabet the NEXT letter uses
            abbrev = false,     ;;; 1..3 while waiting for the second half
            esc    = false,     ;;; 1 = want high bits, 2 = want low bits
            eschi  = 0;
    lvars procedure emit;

    zchars_of(addr) -> (zl, next);

    for z in zl do
        if esc == 1 then
            z -> eschi;
            2 -> esc;
        elseif esc == 2 then
            emit((eschi fi_<< 5) fi_|| z);      ;;; a ten-bit ZSCII code
            false -> esc;
            0 -> alpha;
        elseif abbrev then
            ;;; z-chars 1..3 pick one of three banks of 32 abbreviations
            zm_text_out(zm_abbrev((32 fi_* (abbrev fi_- 1)) fi_+ z), emit) -> ;
            false -> abbrev;
            0 -> alpha;
        elseif z == 0 then
            emit(`\s`);
            0 -> alpha;
        elseif z fi_<= 3 then
            z -> abbrev;
        elseif z == 4 then
            1 -> alpha;                         ;;; shift, for one letter only
        elseif z == 5 then
            2 -> alpha;
        elseif alpha == 2 and z == 6 then
            1 -> esc;                           ;;; next two z-chars spell it
        else
            emit(fast_subscrs(z fi_- 5, fast_subscrv(alpha fi_+ 1, ALPHABETS)));
            0 -> alpha;
        endif;
    endfor;
enddefine;

;;; Collect a string instead of streaming it.
;;;
;;; The collector pushes each character on the open stack and -consstring-
;;; takes them all at the end.  Nested calls (an abbreviation inside a
;;; string) push and consume their own characters in between, which is
;;; exactly what the stack discipline guarantees.
define zm_text(addr) -> str;
    lvars addr, n = 0, str;
    zm_text_out(addr,
        procedure(c);
            lvars c;
            c;                          ;;; leave it on the stack
            n fi_+ 1 -> n;
        endprocedure) -> ;
    consstring(n) -> str;
enddefine;

endsection;
