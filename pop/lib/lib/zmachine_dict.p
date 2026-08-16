/* --- Z-machine dictionary and parsing -----------------------------------
 > File:            pop/lib/lib/zmachine_dict.p
 > Purpose:         Dictionary lookup and input tokenising for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > When you type OPEN MAILBOX, the interpreter does not understand a word
 > of it.  Its whole job is to chop the line into tokens, ENCODE each one
 > back into the same packed z-character form the story file uses, and look
 > that up in the game's own dictionary -- handing the game a list of
 > dictionary addresses.  All the understanding happens in the game.
 >
 > So this file is the mirror of zmachine_text.p: that one unpacks
 > z-characters into letters, this one packs letters into z-characters.
 > Encoding is lossy on purpose -- v3 keeps only the first six
 > z-characters, which is why Zork cannot tell FLASHLIGHT from FLASHLIGH.
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_text;

section $-zmachine =>
        zm_dict_nseps zm_dict_sep zm_dict_entry_len zm_dict_count
        zm_dict_entry zm_dict_lookup zm_encode_word zm_tokenise
    ;

;;; ---- the dictionary's shape --------------------------------------------
;;;
;;; A count of word separators, then those separator characters, then the
;;; length of an entry, then how many entries there are, then the entries.
;;; A NEGATIVE count means the entries are not sorted, so a binary search
;;; would be wrong.

define zm_dict_nseps();
    zm_byte(zm_dict_addr)
enddefine;

define zm_dict_sep(i);
    lvars i;
    zm_byte(zm_dict_addr fi_+ i)
enddefine;

define zm_dict_entry_len();
    zm_byte(zm_dict_addr fi_+ zm_dict_nseps() fi_+ 1)
enddefine;

define zm_dict_count();
    zm_signed(zm_word(zm_dict_addr fi_+ zm_dict_nseps() fi_+ 2))
enddefine;

define lconstant dict_first();
    zm_dict_addr fi_+ zm_dict_nseps() fi_+ 4
enddefine;

define zm_dict_entry(i);
    lvars i;
    dict_first() fi_+ ((i fi_- 1) fi_* zm_dict_entry_len())
enddefine;

;;; How many words of encoded text an entry carries: 2 in v3 (six
;;; z-characters), 3 from v4 (nine).
define lconstant text_words();
    if zm_version fi_<= 3 then 2 else 3 endif
enddefine;

;;; ---- encoding ----------------------------------------------------------

;;; A2 holds digits and punctuation from its third slot on (the first two
;;; are the ten-bit escape and newline), so a character found there is
;;; written as "shift to A2" followed by its position.
lconstant A2_PUNCT = '0123456789.,!?_#\'"/\\-:()';

define lconstant encode_zchars(s, maxz) -> zl;
    lvars s, maxz, i, c, k, n = 0, zl;
    fast_for i from 1 to datalength(s) do
        quitif(n fi_>= maxz);
        uppertolower(fast_subscrs(i, s)) -> c;
        if c fi_>= `a` and c fi_<= `z` then
            c fi_- `a` fi_+ 6;
            n fi_+ 1 -> n;
        elseif (locchar(c, 1, A2_PUNCT) ->> k) then
            ;;; shift, then the character's own place in A2
            5; n fi_+ 1 -> n;
            if n fi_< maxz then
                k fi_+ 7;               ;;; slots 1,2 are escape and newline
                n fi_+ 1 -> n;
            endif;
        else
            ;;; anything else is spelled out in ten bits, which costs four
            ;;; z-characters: shift, escape, high five bits, low five bits
            if n fi_+ 4 fi_<= maxz then
                5; 6; (c fi_>> 5) fi_&& 2:11111; c fi_&& 2:11111;
                n fi_+ 4 -> n;
            else
                quitloop
            endif;
        endif;
    endfor;
    ;;; pad to the full width with 5s, which decode as nothing
    until n fi_>= maxz do 5; n fi_+ 1 -> n enduntil;
    conslist(maxz) -> zl;
enddefine;

;;; The packed form of a word, as a list of 16-bit words ready to compare
;;; against a dictionary entry.  The top bit of the last word marks the end.
define zm_encode_word(s) -> words;
    lvars s, words, nw = text_words(), zl, i, w, z1, z2, z3;
    encode_zchars(s, nw fi_* 3) -> zl;
    fast_for i from 1 to nw do
        dest(zl) -> (z1, zl);
        dest(zl) -> (z2, zl);
        dest(zl) -> (z3, zl);
        (z1 fi_<< 10) fi_|| (z2 fi_<< 5) fi_|| z3 -> w;
        if i == nw then w fi_|| 16:8000 -> w endif;
        w;
    endfor;
    conslist(nw) -> words;
enddefine;

;;; ---- lookup ------------------------------------------------------------

;;; Compare an encoded word with a dictionary entry: -1, 0 or 1.
define lconstant compare_entry(words, addr) -> cmp;
    lvars words, addr, w, i = 0, e, cmp = 0;
    for w in words do
        zm_word(addr fi_+ (i fi_* 2)) -> e;
        if w fi_< e then -1 -> cmp; return
        elseif w fi_> e then 1 -> cmp; return
        endif;
        i fi_+ 1 -> i;
    endfor;
enddefine;

;;; The address of a word's dictionary entry, or 0 if the game does not
;;; know it.  A sorted dictionary (the usual case) is searched by halving;
;;; a game that declares its dictionary unsorted gets a linear scan.
define zm_dict_lookup(s) -> addr;
    lvars s, words = zm_encode_word(s), count = zm_dict_count(),
          lo, hi, mid, cmp, i;
    0 -> addr;
    if count fi_< 0 then
        fast_for i from 1 to negate(count) do
            if compare_entry(words, zm_dict_entry(i)) == 0 then
                zm_dict_entry(i) -> addr; return
            endif
        endfor;
        return
    endif;
    1 -> lo; count -> hi;
    while lo fi_<= hi do
        (lo fi_+ hi) fi_>> 1 -> mid;
        compare_entry(words, zm_dict_entry(mid)) -> cmp;
        if cmp == 0 then
            zm_dict_entry(mid) -> addr; return
        elseif cmp fi_< 0 then
            mid fi_- 1 -> hi
        else
            mid fi_+ 1 -> lo
        endif
    endwhile;
enddefine;

;;; ---- tokenising --------------------------------------------------------

define lconstant is_separator(c);
    lvars c, i;
    fast_for i from 1 to zm_dict_nseps() do
        returnif(zm_dict_sep(i) == c) (true)
    endfor;
    false
enddefine;

;;; Chop the typed line into tokens and fill in the parse buffer the game
;;; handed us.  Its first byte says how many tokens it can hold; we write
;;; the number found into the second, then four bytes per token: where the
;;; word is in the dictionary (0 if unknown), how long it is, and where it
;;; started in the text buffer.
;;;
;;; Word separators (usually the comma and the full stop) are not thrown
;;; away like spaces -- each is a token in its own right, which is how
;;; "TROLL, HELLO" reaches the game as three words.
define zm_tokenise(text, parse_addr);
    lvars text, parse_addr, len = datalength(text), i = 1, start,
          maxtok = zm_byte(parse_addr), ntok = 0, tok, c, entry, p;
    if maxtok == 0 then return endif;

    while i fi_<= len do
        fast_subscrs(i, text) -> c;
        if c == `\s` then
            i fi_+ 1 -> i;
            nextloop
        endif;
        quitif(ntok fi_>= maxtok);
        i -> start;
        if is_separator(c) then
            i fi_+ 1 -> i                       ;;; a separator is one token
        else
            until i fi_> len
               or fast_subscrs(i, text) == `\s`
               or is_separator(fast_subscrs(i, text))
            do
                i fi_+ 1 -> i
            enduntil
        endif;
        substring(start, i fi_- start, text) -> tok;
        zm_dict_lookup(tok) -> entry;

        ;;; four bytes per token, after the two-byte header
        parse_addr fi_+ 2 fi_+ (ntok fi_* 4) -> p;
        entry            -> zm_word(p);
        datalength(tok)  -> zm_byte(p fi_+ 2);
        ;;; the position the game is told is one-based within the buffer,
        ;;; where the text itself starts at byte 1 in v3
        start            -> zm_byte(p fi_+ 3);
        ntok fi_+ 1 -> ntok;
    endwhile;

    ntok -> zm_byte(parse_addr fi_+ 1);
enddefine;

endsection;
