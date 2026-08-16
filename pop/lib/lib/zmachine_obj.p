/* --- Z-machine objects --------------------------------------------------
 > File:            pop/lib/lib/zmachine_obj.p
 > Purpose:         Object tree and properties for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Every noun in the game -- rooms, the brass lantern, you -- is an object
 > in one tree, with a parent, a sibling and a child, a set of on/off
 > attributes, and numbered properties.  "The lamp is in the living room"
 > is literally the lamp's parent pointer.
 >
 > It would be tempting to read this tree into Pop-11 records.  That would
 > be wrong: the game's own code moves objects around and then reads the
 > result back by address, so the story file's bytes have to stay the one
 > source of truth.  What lives here instead is a set of ADDRESS
 > CALCULATORS, with every version difference confined to the few
 > procedures below -- so nothing above this file ever asks what version
 > it is.
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_text;

section $-zmachine =>
        zm_obj_addr zm_obj_count zm_obj_name
        zm_obj_parent zm_obj_sibling zm_obj_child
        zm_obj_attr zm_obj_prop_table
        zm_prop_first zm_prop_next zm_prop_num zm_prop_len zm_prop_data
        zm_obj_prop zm_obj_prop_addr zm_prop_default
    ;

;;; ---- the version-dependent layout, in one place ------------------------
;;;
;;;             property     entry   attribute   parent/sibling/child
;;;             defaults      size     bytes            width
;;;   v1-3      31 words     9 bytes      4            1 byte
;;;   v4+       63 words    14 bytes      6            2 bytes

define lconstant ndefaults();
    if zm_version fi_<= 3 then 31 else 63 endif
enddefine;

define lconstant entry_size();
    if zm_version fi_<= 3 then 9 else 14 endif
enddefine;

define lconstant attr_bytes();
    if zm_version fi_<= 3 then 4 else 6 endif
enddefine;

;;; Objects are numbered from 1; object 0 means "nothing".
define zm_obj_addr(obj);
    lvars obj;
    zm_obj_table fi_+ (ndefaults() fi_* 2)
                 fi_+ ((obj fi_- 1) fi_* entry_size())
enddefine;

;;; A relative (parent/sibling/child) is a byte in v3 and a word in v4+.
define lconstant relative(obj, which);
    lvars obj, which, base = zm_obj_addr(obj) fi_+ attr_bytes();
    if zm_version fi_<= 3 then
        zm_byte(base fi_+ which)
    else
        zm_word(base fi_+ (which fi_* 2))
    endif
enddefine;

define updaterof relative(val, obj, which);
    lvars val, obj, which, base = zm_obj_addr(obj) fi_+ attr_bytes();
    if zm_version fi_<= 3 then
        val -> zm_byte(base fi_+ which)
    else
        val -> zm_word(base fi_+ (which fi_* 2))
    endif
enddefine;

define zm_obj_parent(obj);  lvars obj; relative(obj, 0) enddefine;
define zm_obj_sibling(obj); lvars obj; relative(obj, 1) enddefine;
define zm_obj_child(obj);   lvars obj; relative(obj, 2) enddefine;

define updaterof zm_obj_parent(v, obj);
    lvars v, obj; v -> relative(obj, 0)
enddefine;
define updaterof zm_obj_sibling(v, obj);
    lvars v, obj; v -> relative(obj, 1)
enddefine;
define updaterof zm_obj_child(v, obj);
    lvars v, obj; v -> relative(obj, 2)
enddefine;

;;; Attributes are a bit array, numbered from the most significant bit of
;;; the first byte -- so attribute 0 is 16:80 of byte 0, not 16:01.
define zm_obj_attr(obj, a);
    lvars obj, a;
    (zm_byte(zm_obj_addr(obj) fi_+ (a fi_>> 3))
        fi_>> (7 fi_- (a fi_&& 7))) fi_&& 1 == 1
enddefine;

define updaterof zm_obj_attr(bool, obj, a);
    lvars bool, obj, a,
          addr = zm_obj_addr(obj) fi_+ (a fi_>> 3),
          bit  = 1 fi_<< (7 fi_- (a fi_&& 7));
    if bool then
        (zm_byte(addr) fi_|| bit) -> zm_byte(addr)
    else
        (zm_byte(addr) fi_&& (16:FF fi_- bit)) -> zm_byte(addr)
    endif
enddefine;

;;; The number of objects is not recorded anywhere.  Every story file lays
;;; the property tables out immediately after the last object entry, so the
;;; first object's property table marks the end of the table -- the
;;; standard trick, and the reason a corrupt file shows up as a silly
;;; object count rather than a wild read.
define zm_obj_count();
    lvars first = zm_obj_addr(1);
    (zm_word(first fi_+ attr_bytes() fi_+
             (if zm_version fi_<= 3 then 3 else 6 endif)) fi_- first)
        div entry_size()
enddefine;

define zm_obj_prop_table(obj);
    lvars obj;
    zm_word(zm_obj_addr(obj) fi_+ attr_bytes()
                             fi_+ (if zm_version fi_<= 3 then 3 else 6 endif))
enddefine;

;;; The property table opens with the object's short name: one byte saying
;;; how many WORDS of text follow, then the text itself.
define zm_obj_name(obj);
    lvars obj, p = zm_obj_prop_table(obj);
    if zm_byte(p) == 0 then nullstring else zm_text(p fi_+ 1) endif
enddefine;

;;; ---- properties --------------------------------------------------------
;;;
;;; Properties follow the short name in descending number order, ending at
;;; a zero size byte.  v3 packs number and length into one byte; v4+ uses
;;; a second byte when the length exceeds two.

define zm_prop_first(obj);
    lvars obj, p = zm_obj_prop_table(obj);
    p fi_+ 1 fi_+ (zm_byte(p) fi_* 2)       ;;; skip the short name
enddefine;

define zm_prop_num(paddr);
    lvars paddr, size = zm_byte(paddr);
    if zm_version fi_<= 3 then size fi_&& 2:11111 else size fi_&& 2:111111 endif
enddefine;

define zm_prop_len(paddr);
    lvars paddr, size = zm_byte(paddr), len;
    if zm_version fi_<= 3 then
        (size fi_>> 5) fi_+ 1
    elseif (size fi_&& 16:80) /== 0 then
        ;;; two size bytes: the second holds the length, 0 meaning 64
        (zm_byte(paddr fi_+ 1) fi_&& 2:111111) -> len;
        if len == 0 then 64 else len endif
    elseif (size fi_&& 16:40) /== 0 then
        2
    else
        1
    endif
enddefine;

;;; Where a property's data begins: one size byte in v3, one or two in v4+.
define zm_prop_data(paddr);
    lvars paddr;
    if zm_version fi_<= 3 or (zm_byte(paddr) fi_&& 16:80) == 0 then
        paddr fi_+ 1
    else
        paddr fi_+ 2
    endif
enddefine;

define zm_prop_next(paddr);
    lvars paddr;
    zm_prop_data(paddr) fi_+ zm_prop_len(paddr)
enddefine;

;;; The address of property n's data, or 0 if the object does not have it.
define zm_obj_prop_addr(obj, n);
    lvars obj, n, p = zm_prop_first(obj);
    until zm_byte(p) == 0 do
        returnif(zm_prop_num(p) == n) (zm_prop_data(p));
        zm_prop_next(p) -> p;
    enduntil;
    0
enddefine;

define zm_prop_default(n);
    lvars n;
    zm_word(zm_obj_table fi_+ ((n fi_- 1) fi_* 2))
enddefine;

;;; A property's value, falling back to the defaults table.  Only 1- and
;;; 2-byte properties have a value in this sense (the spec says longer ones
;;; are an error, and real games only ask for the short ones).
define zm_obj_prop(obj, n);
    lvars obj, n, p = zm_prop_first(obj);
    ;;; walk rather than reuse zm_obj_prop_addr: the length lives in the
    ;;; property's own header, which is not always one byte before its data
    until zm_byte(p) == 0 do
        if zm_prop_num(p) == n then
            return(if zm_prop_len(p) == 1 then zm_byte(zm_prop_data(p))
                   else zm_word(zm_prop_data(p))
                   endif)
        endif;
        zm_prop_next(p) -> p;
    enduntil;
    zm_prop_default(n)
enddefine;

endsection;
