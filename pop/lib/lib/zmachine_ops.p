/* --- Z-machine opcodes --------------------------------------------------
 > File:            pop/lib/lib/zmachine_ops.p
 > Purpose:         The instruction set for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Every handler is called the same way: its operands are already on the
 > open stack and the count is its one declared argument.  So a two-operand
 > opcode begins
 >
 >     define lconstant op_add(n);
 >         lvars n, a, b;
 >         () -> (a, b);       ;;; a is the first operand, b the second
 >
 > and a variadic one gathers what it was given with conslist(n).
 >
 > Handlers that produce a value call zm_store; handlers that branch call
 > zm_branch.  Neither is driven by a table: the opcode itself knows.
 >
 > Remember throughout that memory holds UNSIGNED 16-bit words while the
 > arithmetic and comparison opcodes work on SIGNED ones -- every use of
 > zm_signed below is deliberate, and every one that is missing is a bug.
 */
compile_mode :pop11 +strict;

uses zmachine_core;
uses zmachine_dict;
uses zmachine_save;

section $-zmachine;

;;; ---- helpers -----------------------------------------------------------

;;; The length of the property whose DATA starts at addr (what the
;;; get_prop_len opcode is given).  The size byte sits just before it.
define lconstant prop_len_at(addr);
    lvars addr, b;
    returnif(addr == 0) (0);
    zm_byte(addr fi_- 1) -> b;
    if zm_version fi_<= 3 then
        (b fi_>> 5) fi_+ 1
    elseif (b fi_&& 16:80) /== 0 then
        if (b fi_&& 2:111111) == 0 then 64 else b fi_&& 2:111111 endif
    elseif (b fi_&& 16:40) /== 0 then
        2
    else
        1
    endif
enddefine;

;;; Unlink an object from its parent's chain of children.
define lconstant unlink_object(obj);
    lvars obj, parent = zm_obj_parent(obj), c;
    returnif(parent == 0);
    if zm_obj_child(parent) == obj then
        zm_obj_sibling(obj) -> zm_obj_child(parent)
    else
        zm_obj_child(parent) -> c;
        until c == 0 or zm_obj_sibling(c) == obj do
            zm_obj_sibling(c) -> c
        enduntil;
        if c /== 0 then zm_obj_sibling(obj) -> zm_obj_sibling(c) endif
    endif;
    0 -> zm_obj_parent(obj);
    0 -> zm_obj_sibling(obj);
enddefine;

;;; Pull a run of bytes out of story memory as a Pop-11 string.
define lconstant substring_of_memory(addr, len) -> s;
    lvars addr, len, i, s = inits(len);
    fast_for i from 1 to len do
        zm_byte(addr fi_+ i fi_- 1) -> fast_subscrs(i, s)
    endfor
enddefine;

;;; ---- 2OP ---------------------------------------------------------------

;;; je is the one comparison that takes a variable number of operands:
;;; "jump if the first equals ANY of the rest".
define lconstant op_je(n);
    lvars n, args, a, rest, x, hit = false;
    conslist(n) -> args;
    dest(args) -> (a, rest);
    for x in rest do
        if a == x then true -> hit; quitloop endif
    endfor;
    zm_branch(hit);
enddefine;

define lconstant op_jl(n);
    lvars n, a, b;
    () -> (a, b);
    zm_branch(zm_signed(a) fi_< zm_signed(b));
enddefine;

define lconstant op_jg(n);
    lvars n, a, b;
    () -> (a, b);
    zm_branch(zm_signed(a) fi_> zm_signed(b));
enddefine;

;;; dec_chk and inc_chk name their variable indirectly, so they use
;;; zm_var_peek/poke rather than get/put (see zmachine_core.p).
define lconstant op_dec_chk(n);
    lvars n, var, val, now;
    () -> (var, val);
    zm_signed(zm_var_peek(var)) fi_- 1 -> now;
    zm_var_poke(var, now);
    zm_branch(now fi_< zm_signed(val));
enddefine;

define lconstant op_inc_chk(n);
    lvars n, var, val, now;
    () -> (var, val);
    zm_signed(zm_var_peek(var)) fi_+ 1 -> now;
    zm_var_poke(var, now);
    zm_branch(now fi_> zm_signed(val));
enddefine;

define lconstant op_jin(n);
    lvars n, a, b;
    () -> (a, b);
    zm_branch(zm_obj_parent(a) == b);
enddefine;

define lconstant op_test(n);
    lvars n, bitmap, flags;
    () -> (bitmap, flags);
    zm_branch((bitmap fi_&& flags) == flags);
enddefine;

define lconstant op_or(n);
    lvars n, a, b;
    () -> (a, b);
    zm_store(a fi_|| b);
enddefine;

define lconstant op_and(n);
    lvars n, a, b;
    () -> (a, b);
    zm_store(a fi_&& b);
enddefine;

define lconstant op_test_attr(n);
    lvars n, obj, a;
    () -> (obj, a);
    zm_branch(zm_obj_attr(obj, a));
enddefine;

define lconstant op_set_attr(n);
    lvars n, obj, a;
    () -> (obj, a);
    true -> zm_obj_attr(obj, a);
enddefine;

define lconstant op_clear_attr(n);
    lvars n, obj, a;
    () -> (obj, a);
    false -> zm_obj_attr(obj, a);
enddefine;

define lconstant op_store(n);
    lvars n, var, val;
    () -> (var, val);
    zm_var_poke(var, val);
enddefine;

define lconstant op_insert_obj(n);
    lvars n, obj, into;         ;;; not `dest` -- that is Pop-11's own
    () -> (obj, into);
    unlink_object(obj);
    zm_obj_child(into) -> zm_obj_sibling(obj);
    obj  -> zm_obj_child(into);
    into -> zm_obj_parent(obj);
enddefine;

define lconstant op_loadw(n);
    lvars n, array, idx;
    () -> (array, idx);
    zm_store(zm_word(array fi_+ (zm_signed(idx) fi_* 2)));
enddefine;

define lconstant op_loadb(n);
    lvars n, array, idx;
    () -> (array, idx);
    zm_store(zm_byte(array fi_+ zm_signed(idx)));
enddefine;

define lconstant op_get_prop(n);
    lvars n, obj, prop;
    () -> (obj, prop);
    zm_store(zm_obj_prop(obj, prop));
enddefine;

define lconstant op_get_prop_addr(n);
    lvars n, obj, prop;
    () -> (obj, prop);
    zm_store(zm_obj_prop_addr(obj, prop));
enddefine;

;;; get_next_prop(obj, 0) gives the first property number; otherwise the
;;; number of the one after the given property, or 0 at the end.
define lconstant op_get_next_prop(n);
    lvars n, obj, prop, p;
    () -> (obj, prop);
    zm_prop_first(obj) -> p;
    if prop == 0 then
        zm_store(if zm_byte(p) == 0 then 0 else zm_prop_num(p) endif)
    else
        until zm_byte(p) == 0 do
            if zm_prop_num(p) == prop then
                zm_prop_next(p) -> p;
                zm_store(if zm_byte(p) == 0 then 0 else zm_prop_num(p) endif);
                return
            endif;
            zm_prop_next(p) -> p
        enduntil;
        mishap(obj, prop, 2, 'zmachine: get_next_prop on absent property')
    endif
enddefine;

define lconstant op_add(n);
    lvars n, a, b;
    () -> (a, b);
    zm_store(zm_unsigned(zm_signed(a) fi_+ zm_signed(b)));
enddefine;

define lconstant op_sub(n);
    lvars n, a, b;
    () -> (a, b);
    zm_store(zm_unsigned(zm_signed(a) fi_- zm_signed(b)));
enddefine;

define lconstant op_mul(n);
    lvars n, a, b;
    () -> (a, b);
    zm_store(zm_unsigned(zm_signed(a) fi_* zm_signed(b)));
enddefine;

;;; Division truncates toward zero, which is NOT what Pop-11's div and
;;; rem do for negative operands, so the sign is handled explicitly.
define lconstant op_div(n);
    lvars n, a, b, x, y, q;
    () -> (a, b);
    zm_signed(a) -> x; zm_signed(b) -> y;
    if y == 0 then mishap(0, 'zmachine: division by zero') endif;
    (abs(x) div abs(y)) -> q;
    if (x fi_< 0) /== (y fi_< 0) then negate(q) -> q endif;
    zm_store(zm_unsigned(q));
enddefine;

define lconstant op_mod(n);
    lvars n, a, b, x, y, r;
    () -> (a, b);
    zm_signed(a) -> x; zm_signed(b) -> y;
    if y == 0 then mishap(0, 'zmachine: division by zero') endif;
    (abs(x) rem abs(y)) -> r;
    if x fi_< 0 then negate(r) -> r endif;      ;;; sign follows the dividend
    zm_store(zm_unsigned(r));
enddefine;

;;; ---- 1OP ---------------------------------------------------------------

define lconstant op_jz(n);
    lvars n, a;
    () -> a;
    zm_branch(a == 0);
enddefine;

define lconstant op_get_sibling(n);
    lvars n, obj, s;
    () -> obj;
    zm_obj_sibling(obj) -> s;
    zm_store(s);
    zm_branch(s /== 0);
enddefine;

define lconstant op_get_child(n);
    lvars n, obj, c;
    () -> obj;
    zm_obj_child(obj) -> c;
    zm_store(c);
    zm_branch(c /== 0);
enddefine;

define lconstant op_get_parent(n);
    lvars n, obj;
    () -> obj;
    zm_store(zm_obj_parent(obj));
enddefine;

define lconstant op_get_prop_len(n);
    lvars n, addr;
    () -> addr;
    zm_store(prop_len_at(addr));
enddefine;

define lconstant op_inc(n);
    lvars n, var;
    () -> var;
    zm_var_poke(var, zm_unsigned(zm_signed(zm_var_peek(var)) fi_+ 1));
enddefine;

define lconstant op_dec(n);
    lvars n, var;
    () -> var;
    zm_var_poke(var, zm_unsigned(zm_signed(zm_var_peek(var)) fi_- 1));
enddefine;

define lconstant op_print_addr(n);
    lvars n, addr;
    () -> addr;
    zm_text_out(addr, zm_emit) -> ;
enddefine;

define lconstant op_remove_obj(n);
    lvars n, obj;
    () -> obj;
    unlink_object(obj);
enddefine;

define lconstant op_print_obj(n);
    lvars n, obj;
    () -> obj;
    zm_text_out(zm_obj_prop_table(obj) fi_+ 1, zm_emit) -> ;
enddefine;

define lconstant op_ret(n);
    lvars n, v;
    () -> v;
    zm_return(v);
enddefine;

;;; jump takes a SIGNED offset and is not a branch instruction -- there is
;;; no condition byte, and the offset is the operand itself.
define lconstant op_jump(n);
    lvars n, offset;
    () -> offset;
    zm_pc fi_+ zm_signed(offset) fi_- 2 -> zm_pc;
enddefine;

define lconstant op_print_paddr(n);
    lvars n, paddr;
    () -> paddr;
    zm_text_out(zm_unpack_string(paddr), zm_emit) -> ;
enddefine;

define lconstant op_load(n);
    lvars n, var;
    () -> var;
    zm_store(zm_var_peek(var));
enddefine;

;;; 1OP:15 is `not` up to v4; from v5 the encoding was reused for
;;; call_1n -- a call whose result is thrown away.
define lconstant op_not_or_call_1n(n);
    lvars n, a;
    () -> a;
    if zm_version fi_<= 4 then
        zm_store(zm_unsigned(16:FFFF fi_- (a fi_&& 16:FFFF)))
    else
        zm_call(a, [], false)
    endif
enddefine;

define lconstant op_not(n);
    lvars n, a;
    () -> a;
    zm_store(zm_unsigned(16:FFFF fi_- (a fi_&& 16:FFFF)));
enddefine;

;;; ---- 0OP ---------------------------------------------------------------

define lconstant op_rtrue(n);
    lvars n;
    zm_return(1);
enddefine;

define lconstant op_rfalse(n);
    lvars n;
    zm_return(0);
enddefine;

;;; The string to print follows the opcode inline; zm_text_out hands back
;;; the address after it, which is where execution resumes.
define lconstant op_print(n);
    lvars n;
    zm_text_out(zm_pc, zm_emit) -> zm_pc;
enddefine;

define lconstant op_print_ret(n);
    lvars n;
    zm_text_out(zm_pc, zm_emit) -> zm_pc;
    zm_emit(13);
    zm_return(1);
enddefine;

define lconstant op_nop(n);
    lvars n;
enddefine;

define lconstant op_ret_popped(n);
    lvars n;
    zm_return(zm_pop());
enddefine;

;;; 0OP:9 is pop up to v4 and catch from v5.  catch hands the game a token
;;; for the current call depth, which throw later unwinds back to.
define lconstant op_pop_or_catch(n);
    lvars n;
    if zm_version fi_<= 4 then
        zm_pop() -> 
    else
        zm_store(listlength(zm_frames) fi_+ 1)
    endif
enddefine;

define lconstant op_quit(n);
    lvars n;
    false -> zm_running;
enddefine;

define lconstant op_new_line(n);
    lvars n;
    zm_emit(13);
enddefine;

;;; In v3 the interpreter draws the status line; the front end decides
;;; whether it has anywhere to draw it.  Global 1 is the current room,
;;; globals 2 and 3 the score and turns.
define lconstant show_status();
    zio_status(zm_obj_name(zm_var_get(16)),
               zm_signed(zm_var_get(17)),
               zm_signed(zm_var_get(18)));
enddefine;

define lconstant op_show_status(n);
    lvars n;
    show_status();
enddefine;

;;; In v3 save and restore BRANCH rather than store.  The program counter
;;; written into a save file points at this instruction's own branch data,
;;; so a restore resumes here and takes that branch as the success -- which
;;; is why a restored v3 game continues from the save opcode, not the
;;; restore one.
;;; v3 branches on the result; v4 stores it; from v5 these live in the
;;; extended table instead (EXT:0 and EXT:1) and store as well.
define lconstant op_save(n);
    lvars n, ok;
    zm_save_state() -> ok;
    if zm_version fi_<= 3 then
        zm_branch(ok)
    else
        zm_store(if ok then 1 else 0 endif)
    endif
enddefine;

define lconstant op_restore(n);
    lvars n, ok;
    zm_restore_state() -> ok;
    if zm_version fi_<= 3 then
        ;;; a restored v3 game resumes at the SAVE instruction's branch
        ;;; data, and takes that branch as its success
        zm_branch(ok)
    elseif ok then
        ;;; likewise from v4, except that save stored rather than branched:
        ;;; the resumed store writes 2, meaning "this is a restored game"
        zm_store(2)
    else
        zm_store(0)
    endif
enddefine;

;;; verify compares the published checksum with a sum over the story as
;;; PUBLISHED -- not over live memory, which the game has been writing to
;;; since it started.  (CZECH catches an interpreter that gets this wrong.)
define lconstant op_verify(n);
    lvars n;
    zm_branch(zm_story_checksum() == zm_checksum);
enddefine;

;;; restart puts dynamic memory back and begins again; the header bits the
;;; interpreter owns are re-applied by zm_reset.
define lconstant op_restart(n);
    lvars n;
    zm_restore_dynamic();
    zm_reset();
enddefine;

;;; ---- VAR ---------------------------------------------------------------

define lconstant op_call(n);
    lvars n, args, routine;
    if n == 0 then
        mishap(zm_pc, 1, 'zmachine: call with no routine operand')
    endif;
    conslist(n) -> args;
    dest(args) -> (routine, args);
    ;;; the store byte follows the operands, so it must be read before the
    ;;; call moves the PC
    zm_call(routine, args, zm_fetch_byte());
enddefine;

;;; call_1s/call_2s/call_vs2 store their result; call_1n/call_2n/call_vn/
;;; call_vn2 discard it.  All of them are zm_call with a different idea of
;;; where the answer goes.
define lconstant op_call_store(n);
    lvars n, args, routine;
    conslist(n) -> args;
    dest(args) -> (routine, args);
    zm_call(routine, args, zm_fetch_byte());
enddefine;

define lconstant op_call_discard(n);
    lvars n, args, routine;
    conslist(n) -> args;
    dest(args) -> (routine, args);
    zm_call(routine, args, false);
enddefine;

;;; throw unwinds the call stack back to the depth a catch recorded, and
;;; returns the given value from there.
define lconstant op_throw(n);
    lvars n, value, frame;
    () -> (value, frame);
    until (listlength(zm_frames) fi_+ 1) fi_<= frame or zm_frames == [] do
        fast_destpair(zm_frames) -> zm_frames -> zm_frame
    enduntil;
    zm_return(value);
enddefine;

define lconstant op_check_arg_count(n);
    lvars n, k;
    () -> k;
    zm_branch(k fi_<= zf_nargs(zm_frame));
enddefine;

;;; log_shift fills with zeros; art_shift keeps the sign when shifting right
define lconstant op_log_shift(n);
    lvars n, number, places;
    () -> (number, places);
    zm_signed(places) -> places;
    zm_store(if places fi_>= 0 then
                 zm_unsigned(number fi_<< places)
             else
                 (number fi_&& 16:FFFF) fi_>> negate(places)
             endif);
enddefine;

define lconstant op_art_shift(n);
    lvars n, number, places;
    () -> (number, places);
    zm_signed(places) -> places;
    zm_store(if places fi_>= 0 then
                 zm_unsigned(zm_signed(number) fi_<< places)
             else
                 zm_unsigned(zm_signed(number) fi_>> negate(places))
             endif);
enddefine;

;;; scan_table looks for a value in an array of records.  The form byte
;;; says whether the fields are words or bytes (bit 7) and how far apart
;;; they are (the rest); the default is words, two bytes apart.
define lconstant op_scan_table(n);
    lvars n, args, x, table, len, form = 16:82, i, addr, fieldlen, wordwise;
                                    ;;; not `isword` -- Pop-11 owns that
    conslist(n) -> args;
    args(1) -> x; args(2) -> table; args(3) -> len;
    if listlength(args) fi_>= 4 then args(4) -> form endif;
    form fi_&& 2:1111111 -> fieldlen;
    (form fi_&& 16:80) /== 0 -> wordwise;
    fast_for i from 0 to len fi_- 1 do
        table fi_+ (i fi_* fieldlen) -> addr;
        if (if wordwise then zm_word(addr) else zm_byte(addr) endif) == x then
            zm_store(addr);
            zm_branch(true);
            return
        endif
    endfor;
    zm_store(0);
    zm_branch(false);
enddefine;

;;; copy_table zeroes a block when its destination is 0, and otherwise
;;; copies -- backwards when the blocks overlap the wrong way, unless a
;;; negative size says the game wants a plain forward copy.
define lconstant op_copy_table(n);
    lvars n, first, second, size, i;
    () -> (first, second, size);
    zm_signed(size) -> size;
    if second == 0 then
        fast_for i from 0 to abs(size) fi_- 1 do 0 -> zm_byte(first fi_+ i) endfor
    elseif size fi_< 0 or first fi_> second then
        fast_for i from 0 to abs(size) fi_- 1 do
            zm_byte(first fi_+ i) -> zm_byte(second fi_+ i)
        endfor
    else
        fast_for i from size fi_- 1 by -1 to 0 do
            zm_byte(first fi_+ i) -> zm_byte(second fi_+ i)
        endfor
    endif
enddefine;

;;; print_table prints a rectangle of characters out of memory
define lconstant op_print_table(n);
    lvars n, args, text, width, height = 1, skip = 0, r, c;
    conslist(n) -> args;
    args(1) -> text; args(2) -> width;
    if listlength(args) fi_>= 3 then args(3) -> height endif;
    if listlength(args) fi_>= 4 then args(4) -> skip endif;
    fast_for r from 0 to height fi_- 1 do
        fast_for c from 0 to width fi_- 1 do
            zm_emit(zm_byte(text fi_+ c))
        endfor;
        text fi_+ width fi_+ skip -> text;
        if r fi_< height fi_- 1 then zm_emit(13) endif
    endfor
enddefine;

define lconstant op_read_char(n);
    lvars n;
    erasenum(n);
    zm_store(zio_read_char());
enddefine;

define lconstant op_tokenise(n);
    lvars n, args, text_addr, parse_addr, i, len, line;
    conslist(n) -> args;
    args(1) -> text_addr; args(2) -> parse_addr;
    ;;; recover the text the game has in its buffer and re-tokenise it
    if zm_version fi_<= 4 then
        1 -> i; 0 -> len;
        until zm_byte(text_addr fi_+ 1 fi_+ len) == 0 do len fi_+ 1 -> len enduntil;
        substring_of_memory(text_addr fi_+ 1, len) -> line;
        zm_tokenise(line, parse_addr, 1)
    else
        zm_byte(text_addr fi_+ 1) -> len;
        substring_of_memory(text_addr fi_+ 2, len) -> line;
        zm_tokenise(line, parse_addr, 2)
    endif
enddefine;

define lconstant op_storew(n);
    lvars n, array, idx, val;
    () -> (array, idx, val);
    zm_unsigned(val) -> zm_word(array fi_+ (zm_signed(idx) fi_* 2));
enddefine;

define lconstant op_storeb(n);
    lvars n, array, idx, val;
    () -> (array, idx, val);
    (val fi_&& 16:FF) -> zm_byte(array fi_+ zm_signed(idx));
enddefine;

define lconstant op_put_prop(n);
    lvars n, obj, prop, val, a;
    () -> (obj, prop, val);
    zm_obj_prop_addr(obj, prop) -> a;
    if a == 0 then
        mishap(obj, prop, 2, 'zmachine: put_prop on absent property')
    endif;
    if prop_len_at(a) == 1 then
        (val fi_&& 16:FF) -> zm_byte(a)
    else
        zm_unsigned(val) -> zm_word(a)
    endif
enddefine;

define lconstant op_print_char(n);
    lvars n, c;
    () -> c;
    zm_emit(c);
enddefine;

define lconstant op_print_num(n);
    lvars n, v;
    () -> v;
    zm_out_num(zm_signed(v));
enddefine;

;;; random(r) with r > 0 gives 1..r; with r <= 0 it (re)seeds, and
;;; produces nothing.
define lconstant op_random(n);
    lvars n, r;
    () -> r;
    zm_signed(r) -> r;
    if r fi_> 0 then
        zm_store(random(r))
    else
        if r fi_< 0 then negate(r) -> ranseed endif;
        zm_store(0)
    endif
enddefine;

define lconstant op_push(n);
    lvars n, v;
    () -> v;
    zm_push(v);
enddefine;

define lconstant op_pull(n);
    lvars n, var;
    () -> var;
    ;;; pull names its destination indirectly, but the value it moves does
    ;;; come off the stack
    zm_var_poke(var, zm_pop());
enddefine;

;;; sread is where the game hands control back to the player: read a line,
;;; store it in the game's text buffer, and chop it into dictionary
;;; references in the game's parse buffer.  In v3 the status line is
;;; redrawn first -- the game never does that itself.
define lconstant op_sread(n);
    lvars n, args, text_addr, parse_addr = 0, line, maxlen, i, len;
    conslist(n) -> args;
    args(1) -> text_addr;
    if listlength(args) fi_>= 2 then args(2) -> parse_addr endif;
    ;;; only v1-3 have the interpreter draw the status line
    if zm_version fi_<= 3 then show_status() endif;
    zio_read_line() -> line;

    ;;; The dictionary is written in lower case, so input is folded before
    ;;; it is stored OR tokenised.
    fast_for i from 1 to datalength(line) do
        uppertolower(fast_subscrs(i, line)) -> fast_subscrs(i, line)
    endfor;

    zm_byte(text_addr) -> maxlen;
    if datalength(line) fi_> maxlen then
        substring(1, maxlen, line) -> line
    endif;
    datalength(line) -> len;

    if zm_version fi_<= 4 then
        ;;; text from byte 1, ended by a zero
        fast_for i from 1 to len do
            fast_subscrs(i, line) -> zm_byte(text_addr fi_+ i)
        endfor;
        0 -> zm_byte(text_addr fi_+ len fi_+ 1);
        if parse_addr /== 0 then zm_tokenise(line, parse_addr, 1) endif
    else
        ;;; from v5 byte 1 holds the count and the text begins at byte 2;
        ;;; parsing is optional, and the key that ended the line is stored
        len -> zm_byte(text_addr fi_+ 1);
        fast_for i from 1 to len do
            fast_subscrs(i, line) -> zm_byte(text_addr fi_+ 1 fi_+ i)
        endfor;
        if parse_addr /== 0 then zm_tokenise(line, parse_addr, 2) endif;
        zm_store(13)
    endif
enddefine;

;;; split_window reserves lines at the top of the screen; set_window
;;; chooses which window print goes to.  Switching back to the main window
;;; means the status bar has just been drawn in full, so that is when the
;;; front end is handed it.
define lconstant op_split_window(n);
    lvars n, lines;
    () -> lines;
    lines -> zm_upper_height;
enddefine;

define lconstant op_set_window(n);
    lvars n, w;
    () -> w;
    if w == 0 and zm_window /== 0 then zm_upper_flush() endif;
    w -> zm_window;
enddefine;

define lconstant op_erase_window(n);
    lvars n, w;
    () -> w;
    if zm_window /== 0 then zm_upper_flush() endif;
enddefine;

;;; Stream 1 is the screen and is always on; 2 is a transcript file and 4 a
;;; record of commands, neither of which we keep; 3 redirects into a table
;;; in the game's memory and is the one that matters.
define lconstant op_output_stream(n);
    lvars n, args, num, table;
    conslist(n) -> args;
    zm_signed(args(1)) -> num;
    if num == 3 then
        args(2) -> table;
        0 -> zm_word(table);            ;;; the table starts empty
        conspair(table, zm_mem_streams) -> zm_mem_streams;
    elseif num == -3 then
        if zm_mem_streams /== [] then
            fast_back(zm_mem_streams) -> zm_mem_streams
        endif;
    endif
enddefine;

;;; Window and stream control: accepted and ignored until a front end has
;;; somewhere to put them (M6).
define lconstant op_ignore1(n);
    lvars n;
    erasenum(n);
enddefine;

;;; The piracy opcode lets a game ask whether it thinks it is a legitimate
;;; copy.  The standard's advice is to always branch.
define lconstant op_piracy(n);
    lvars n;
    zm_branch(true);
enddefine;

;;; save_undo/restore_undo: a game may ask for a single-turn undo.  We do
;;; not keep an undo buffer yet, so we answer "not supported" (-1), which
;;; every well-behaved game handles.
define lconstant op_save_undo(n);
    lvars n;
    erasenum(n);
    zm_store(zm_unsigned(-1));
enddefine;

define lconstant op_restore_undo(n);
    lvars n;
    erasenum(n);
    zm_store(0);
enddefine;

;;; ---- install -----------------------------------------------------------

;;; 2OP at 0, 1OP at 128, 0OP at 176, VAR at 224 -- the standard numbering,
;;; which is what makes one flat table possible.
define lconstant install(idx, p);
    lvars idx, procedure p;
    p -> fast_subscrv(idx fi_+ 1, zm_ops);
enddefine;

install(1,  op_je);             install(2,  op_jl);
install(3,  op_jg);             install(4,  op_dec_chk);
install(5,  op_inc_chk);        install(6,  op_jin);
install(7,  op_test);           install(8,  op_or);
install(9,  op_and);            install(10, op_test_attr);
install(11, op_set_attr);       install(12, op_clear_attr);
install(13, op_store);          install(14, op_insert_obj);
install(15, op_loadw);          install(16, op_loadb);
install(17, op_get_prop);       install(18, op_get_prop_addr);
install(19, op_get_next_prop);  install(20, op_add);
install(21, op_sub);            install(22, op_mul);
install(23, op_div);            install(24, op_mod);

install(128, op_jz);            install(129, op_get_sibling);
install(130, op_get_child);     install(131, op_get_parent);
install(132, op_get_prop_len);  install(133, op_inc);
install(134, op_dec);           install(135, op_print_addr);
install(137, op_remove_obj);    install(138, op_print_obj);
install(139, op_ret);           install(140, op_jump);
install(141, op_print_paddr);   install(142, op_load);
install(143, op_not_or_call_1n);

install(176, op_rtrue);         install(177, op_rfalse);
install(178, op_print);         install(179, op_print_ret);
install(180, op_nop);           install(184, op_ret_popped);
install(185, op_pop_or_catch);  install(186, op_quit);
install(187, op_new_line);      install(188, op_show_status);
install(181, op_save);         install(182, op_restore);
install(183, op_restart);      install(189, op_verify);

install(25, op_call_store);     install(26, op_call_discard);
install(27, op_ignore1);        install(28, op_throw);
install(136, op_call_store);
install(191, op_piracy);

install(224, op_call);          install(225, op_storew);
install(226, op_storeb);        install(227, op_put_prop);
install(228, op_sread);
install(229, op_print_char);    install(230, op_print_num);
install(231, op_random);        install(232, op_push);
install(233, op_pull);          install(234, op_split_window);
install(235, op_set_window);    install(236, op_call_store);
install(237, op_erase_window);       install(238, op_ignore1);
install(239, op_ignore1);       install(240, op_ignore1);
install(241, op_ignore1);       install(242, op_ignore1);
install(243, op_output_stream); install(244, op_ignore1);
install(245, op_ignore1);       install(246, op_read_char);
install(247, op_scan_table);    install(248, op_not);
install(249, op_call_discard);  install(250, op_call_discard);
install(251, op_tokenise);      install(253, op_copy_table);
install(254, op_print_table);   install(255, op_check_arg_count);

;;; the extended table (v5+)
define lconstant install_ext(idx, p);
    lvars idx, procedure p;
    p -> fast_subscrv(idx fi_+ 1, zm_ops_ext);
enddefine;

install_ext(0, op_save);        install_ext(1, op_restore);
install_ext(2, op_log_shift);   install_ext(3, op_art_shift);
install_ext(4, op_ignore1);     install_ext(9, op_save_undo);
install_ext(10, op_restore_undo);

endsection;
