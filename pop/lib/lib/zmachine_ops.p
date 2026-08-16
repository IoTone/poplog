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
    zm_text_out(addr, zio_char) -> ;
enddefine;

define lconstant op_remove_obj(n);
    lvars n, obj;
    () -> obj;
    unlink_object(obj);
enddefine;

define lconstant op_print_obj(n);
    lvars n, obj;
    () -> obj;
    zm_text_out(zm_obj_prop_table(obj) fi_+ 1, zio_char) -> ;
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
    zm_text_out(zm_unpack_string(paddr), zio_char) -> ;
enddefine;

define lconstant op_load(n);
    lvars n, var;
    () -> var;
    zm_store(zm_var_peek(var));
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
    zm_text_out(zm_pc, zio_char) -> zm_pc;
enddefine;

define lconstant op_print_ret(n);
    lvars n;
    zm_text_out(zm_pc, zio_char) -> zm_pc;
    zio_char(13);
    zm_return(1);
enddefine;

define lconstant op_nop(n);
    lvars n;
enddefine;

define lconstant op_ret_popped(n);
    lvars n;
    zm_return(zm_pop());
enddefine;

define lconstant op_pop(n);
    lvars n;
    zm_pop() -> ;
enddefine;

define lconstant op_quit(n);
    lvars n;
    false -> zm_running;
enddefine;

define lconstant op_new_line(n);
    lvars n;
    zio_char(13);
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
define lconstant op_save(n);
    lvars n;
    zm_branch(zm_save_state());
enddefine;

define lconstant op_restore(n);
    lvars n;
    if zm_restore_state() then
        zm_branch(true)
    else
        zm_branch(false)
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
    zio_char(c);
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
    lvars n, text_addr, parse_addr, line, maxlen, i, len, c;
    () -> (text_addr, parse_addr);
    show_status();
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
    fast_for i from 1 to len do
        fast_subscrs(i, line) -> zm_byte(text_addr fi_+ i)
    endfor;
    0 -> zm_byte(text_addr fi_+ len fi_+ 1);        ;;; the terminator

    zm_tokenise(line, parse_addr);
enddefine;

;;; Window and stream control: accepted and ignored until a front end has
;;; somewhere to put them (M6).
define lconstant op_ignore1(n);
    lvars n;
    erasenum(n);
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
install(143, op_not);

install(176, op_rtrue);         install(177, op_rfalse);
install(178, op_print);         install(179, op_print_ret);
install(180, op_nop);           install(184, op_ret_popped);
install(185, op_pop);           install(186, op_quit);
install(187, op_new_line);      install(188, op_show_status);
install(181, op_save);         install(182, op_restore);
install(183, op_restart);      install(189, op_verify);

install(224, op_call);          install(225, op_storew);
install(226, op_storeb);        install(227, op_put_prop);
install(228, op_sread);
install(229, op_print_char);    install(230, op_print_num);
install(231, op_random);        install(232, op_push);
install(233, op_pull);          install(234, op_ignore1);
install(235, op_ignore1);       install(243, op_ignore1);
install(244, op_ignore1);

endsection;
