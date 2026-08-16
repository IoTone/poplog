/* --- The Z-machine itself -----------------------------------------------
 > File:            pop/lib/lib/zmachine_core.p
 > Purpose:         Stack, frames, decoder and execution loop for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > A Z-machine instruction is one opcode byte, up to eight operands, and
 > optionally a byte saying where to store the result and/or an offset to
 > branch to.  Everything interesting is in how the opcode byte encodes
 > which of the four FORMS it is, and how many operands follow:
 >
 >     $00..$7F  long      always two operands, types in bits 6 and 5
 >     $80..$BF  short     one operand, or none if its type says "omitted"
 >     $C0..$FF  variable  a following byte gives four 2-bit operand types
 >     $BE       extended  (v5+) a second opcode byte, then types
 >
 > The four forms collapse into ONE 256-entry table of procedures using the
 > standard numbering (2OP at 0, 1OP at 128, 0OP at 176, VAR at 224), so
 > dispatch is a single vector subscript.
 >
 > Operands are passed to the handlers ON THE OPEN STACK with the count on
 > top -- the Z-machine is a stack machine and so is Pop-11, so no list or
 > vector is built per instruction.  Every handler is declared the same
 > way:   define op_add(n); lvars n, a, b; () -> (a, b); ...
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_text;
uses zmachine_obj;
uses zmachine_io;

section $-zmachine =>
        zm_pc zm_running zm_sp zm_stack zm_frame zm_frames zm_max_steps
        zf_return_pc zf_store_var zf_locals zf_nargs zf_eval_base
        zm_push zm_pop zm_var_get zm_var_put zm_var_peek zm_var_poke
        zm_fetch_byte zm_fetch_word zm_store zm_branch
        zm_call zm_return
        zm_ops zm_ops_ext zm_op_name zm_reset zm_step zm_run zm_play
    ;

;;; A call frame.  The evaluation stack is shared and one deep chain of
;;; these hangs off it, each remembering where its slice began -- which is
;;; what lets a return discard whatever the routine left lying around, and
;;; what a Quetzal save file will walk when we get to M5.
defclass zframe {
    zf_return_pc,       ;;; where to resume in the caller
    zf_store_var,       ;;; variable to put the result in, or false
    zf_locals,          ;;; intvec of 15 (locals are numbered 1..15)
    zf_nargs,           ;;; how many arguments were actually supplied
    zf_eval_base        ;;; zm_sp on entry
};

;;; zm_branch can end a routine (offsets 0 and 1 mean return), so it needs
;;; zm_return before that is defined.
constant procedure zm_return;

vars
    zm_pc       = 0,
    zm_running  = false,
    zm_stack    = false,        ;;; the shared evaluation stack, an intvec
    zm_sp       = 0,
    zm_frame    = false,        ;;; the frame we are executing in
    zm_frames   = [],           ;;; its callers, innermost first
    zm_max_steps = false,       ;;; a safety net for tests; false = no limit
    ;

;;; --- the evaluation stack ----------------------------------------------

define zm_push(v);
    lvars v;
    zm_sp fi_+ 1 -> zm_sp;
    if zm_sp fi_> datalength(zm_stack) then
        mishap(zm_pc, 1, 'zmachine: evaluation stack overflow')
    endif;
    zm_unsigned(v) -> subscrintvec(zm_sp, zm_stack);
enddefine;

define zm_pop();
    if zm_sp fi_<= 0 then
        mishap(zm_pc, 1, 'zmachine: evaluation stack underflow')
    endif;
    subscrintvec(zm_sp, zm_stack);          ;;; the result
    zm_sp fi_- 1 -> zm_sp;
enddefine;

;;; --- variables ----------------------------------------------------------
;;;
;;; Variable 0 is the stack, 1..15 are the current routine's locals, and
;;; 16..255 are globals living in dynamic memory.

define zm_var_get(n);
    lvars n;
    if n == 0 then
        zm_pop()
    elseif n fi_<= 15 then
        subscrintvec(n, zf_locals(zm_frame))
    else
        zm_word(zm_globals fi_+ ((n fi_- 16) fi_* 2))
    endif
enddefine;

define zm_var_put(n, v);
    lvars n, v;
    if n == 0 then
        zm_push(v)
    elseif n fi_<= 15 then
        zm_unsigned(v) -> subscrintvec(n, zf_locals(zm_frame))
    else
        zm_unsigned(v) -> zm_word(zm_globals fi_+ ((n fi_- 16) fi_* 2))
    endif
enddefine;

;;; The seven opcodes that name a variable INDIRECTLY (load, store, pull,
;;; inc, dec, inc_chk, dec_chk) must not push or pop when that variable is
;;; the stack -- they read and replace the top item in place.  CZECH tests
;;; this, and getting it wrong corrupts the stack in ways that surface far
;;; from the cause.
define zm_var_peek(n);
    lvars n;
    if n == 0 then subscrintvec(zm_sp, zm_stack) else zm_var_get(n) endif
enddefine;

define zm_var_poke(n, v);
    lvars n, v;
    if n == 0 then
        zm_unsigned(v) -> subscrintvec(zm_sp, zm_stack)
    else
        zm_var_put(n, v)
    endif
enddefine;

;;; --- fetching -----------------------------------------------------------

define zm_fetch_byte();
    lvars b = zm_byte(zm_pc);
    zm_pc fi_+ 1 -> zm_pc;
    b
enddefine;

define zm_fetch_word();
    lvars w = zm_word(zm_pc);
    zm_pc fi_+ 2 -> zm_pc;
    w
enddefine;

;;; --- storing and branching ----------------------------------------------
;;;
;;; Which opcodes store a result, and which branch, is not kept in a table
;;; here: each handler calls zm_store or zm_branch itself, because the
;;; handler is the one place that already knows.

define zm_store(v);
    lvars v;
    zm_var_put(zm_fetch_byte(), v)
enddefine;

;;; Branch data is the fiddliest encoding in the format, so it is written
;;; out once, here.  Bit 7 of the first byte says whether we branch when
;;; the condition is TRUE or when it is FALSE.  Bit 6 says the offset is
;;; the remaining 6 bits (unsigned); otherwise it is a 14-bit signed offset
;;; spanning this byte and the next.  Offsets 0 and 1 do not mean "jump
;;; nowhere" -- they mean return false and return true.
define zm_branch(flag);
    lvars flag, b = zm_fetch_byte(), offset, on_true;
    (b fi_&& 16:80) /== 0 -> on_true;
    if (b fi_&& 16:40) /== 0 then
        b fi_&& 2:111111 -> offset
    else
        ((b fi_&& 2:111111) fi_<< 8) fi_|| zm_fetch_byte() -> offset;
        if offset fi_>= 16:2000 then offset fi_- 16:4000 -> offset endif
    endif;
    if (flag and on_true) or not(flag or on_true) then
        if offset == 0 then
            zm_return(0)
        elseif offset == 1 then
            zm_return(1)
        else
            zm_pc fi_+ offset fi_- 2 -> zm_pc
        endif
    endif
enddefine;

;;; --- calling and returning ----------------------------------------------

define zm_call(paddr, arglist, store_var);
    lvars paddr, arglist, store_var, addr, nlocals, locals, i, a, n = 0;

    ;;; "Calling" address 0 is legal and simply produces false.
    if paddr == 0 then
        if store_var then zm_var_put(store_var, 0) endif;
        return
    endif;

    zm_unpack_routine(paddr) -> addr;
    zm_byte(addr) -> nlocals;
    addr fi_+ 1 -> addr;
    if nlocals fi_> 15 then
        mishap(nlocals, addr, 2, 'zmachine: routine claims too many locals')
    endif;

    initintvec(15) -> locals;
    ;;; In v1-4 the routine header carries each local's initial value; from
    ;;; v5 they simply start at zero.
    fast_for i from 1 to nlocals do
        if zm_version fi_<= 4 then
            zm_word(addr) -> subscrintvec(i, locals);
            addr fi_+ 2 -> addr
        else
            0 -> subscrintvec(i, locals)
        endif
    endfor;

    ;;; arguments overwrite the first locals; surplus arguments are dropped
    for a in arglist do
        n fi_+ 1 -> n;
        if n fi_<= nlocals then a -> subscrintvec(n, locals) endif
    endfor;

    conspair(zm_frame, zm_frames) -> zm_frames;
    conszframe(zm_pc, store_var, locals, n, zm_sp) -> zm_frame;
    addr -> zm_pc;
enddefine;

define zm_return(v);
    lvars v, f = zm_frame;
    if zm_frames == [] then
        ;;; returning out of the main routine ends the game
        false -> zm_running;
        return
    endif;
    zf_eval_base(f) -> zm_sp;           ;;; drop anything left on the stack
    zf_return_pc(f) -> zm_pc;
    fast_destpair(zm_frames) -> zm_frames -> zm_frame;
    ;;; store_var is false for the call_n opcodes, which discard the result
    if zf_store_var(f) then zm_var_put(zf_store_var(f), v) endif;
enddefine;

;;; --- the opcode tables --------------------------------------------------

lconstant
    OP2_NAMES = { 'none' 'je' 'jl' 'jg' 'dec_chk' 'inc_chk' 'jin' 'test'
        'or' 'and' 'test_attr' 'set_attr' 'clear_attr' 'store' 'insert_obj'
        'loadw' 'loadb' 'get_prop' 'get_prop_addr' 'get_next_prop' 'add'
        'sub' 'mul' 'div' 'mod' 'call_2s' 'call_2n' 'set_colour' 'throw'
        'op29' 'op30' 'op31' },
    OP1_NAMES = { 'jz' 'get_sibling' 'get_child' 'get_parent' 'get_prop_len'
        'inc' 'dec' 'print_addr' 'call_1s' 'remove_obj' 'print_obj' 'ret'
        'jump' 'print_paddr' 'load' 'not/call_1n' },
    OP0_NAMES = { 'rtrue' 'rfalse' 'print' 'print_ret' 'nop' 'save'
        'restore' 'restart' 'ret_popped' 'pop/catch' 'quit' 'new_line'
        'show_status' 'verify' 'extended' 'piracy' },
    OPV_NAMES = { 'call' 'storew' 'storeb' 'put_prop' 'sread' 'print_char'
        'print_num' 'random' 'push' 'pull' 'split_window' 'set_window'
        'call_vs2' 'erase_window' 'erase_line' 'set_cursor' 'get_cursor'
        'set_text_style' 'buffer_mode' 'output_stream' 'input_stream'
        'sound_effect' 'read_char' 'scan_table' 'not' 'call_vn' 'call_vn2'
        'tokenise' 'encode_text' 'copy_table' 'print_table'
        'check_arg_count' },
    ;

define zm_op_name(idx);
    lvars idx;
    if idx fi_< 32 then
        '2OP:' sys_>< idx sys_>< ' (' sys_>< fast_subscrv(idx fi_+ 1, OP2_NAMES) sys_>< ')'
    elseif idx fi_>= 128 and idx fi_< 144 then
        '1OP:' sys_>< (idx fi_- 128) sys_><
            ' (' sys_>< fast_subscrv(idx fi_- 127, OP1_NAMES) sys_>< ')'
    elseif idx fi_>= 176 and idx fi_< 192 then
        '0OP:' sys_>< (idx fi_- 176) sys_><
            ' (' sys_>< fast_subscrv(idx fi_- 175, OP0_NAMES) sys_>< ')'
    elseif idx fi_>= 224 then
        'VAR:' sys_>< (idx fi_- 224) sys_><
            ' (' sys_>< fast_subscrv(idx fi_- 223, OPV_NAMES) sys_>< ')'
    else
        'opcode ' sys_>< idx
    endif
enddefine;

;;; An unfilled slot is not a crash but a precise request: it names the
;;; opcode and where the game asked for it, which is exactly the loop we
;;; develop by -- run it, see what it asks for, write that one.
define lconstant unimplemented(idx, n);
    lvars idx, n;
    erasenum(n);                    ;;; discard the operands
    mishap(0, 'zmachine: unimplemented opcode ' sys_>< zm_op_name(idx)
                sys_>< ' at PC ' sys_>< zm_pc)
enddefine;

constant zm_ops = initv(256), zm_ops_ext = initv(256);

lvars i;
for i from 0 to 255 do
    unimplemented(% i %) -> fast_subscrv(i fi_+ 1, zm_ops);
    unimplemented(% i %) -> fast_subscrv(i fi_+ 1, zm_ops_ext);
endfor;

;;; --- decode and execute -------------------------------------------------

define lconstant read_operand(type);
    lvars type;
    if type == 1 then zm_fetch_byte()
    elseif type == 2 then zm_var_get(zm_fetch_byte())
    else zm_fetch_word()                        ;;; type 0, a large constant
    endif
enddefine;

;;; Read the operands described by a types byte, pushing each on the stack.
;;; The first "omitted" type ends the list.
define lconstant read_typed_operands(types) -> n;
    lvars types, t, i, n = 0;
    fast_for i from 0 to 3 do
        (types fi_>> (6 fi_- (i fi_* 2))) fi_&& 2:11 -> t;
        quitif(t == 3);
        read_operand(t);
        n fi_+ 1 -> n;
    endfor
enddefine;

define zm_step();
    lvars op, idx, n;

    zm_fetch_byte() -> op;

    if op fi_< 16:80 then
        ;;; long form: two operands, bit 6 and bit 5 saying small-constant
        ;;; (0) or variable (1) for the first and second
        read_operand(if (op fi_&& 16:40) == 0 then 1 else 2 endif);
        read_operand(if (op fi_&& 16:20) == 0 then 1 else 2 endif);
        2 -> n;
        op fi_&& 2:11111 -> idx;

    elseif op fi_< 16:C0 then
        ;;; short form: the operand type is in bits 5-4, and "omitted"
        ;;; there is what makes this a 0OP instruction
        if ((op fi_>> 4) fi_&& 2:11) == 3 then
            0 -> n;
            176 fi_+ (op fi_&& 2:1111) -> idx
        else
            read_operand((op fi_>> 4) fi_&& 2:11);
            1 -> n;
            128 fi_+ (op fi_&& 2:1111) -> idx
        endif;

    else
        ;;; variable form: a types byte follows.  Bit 5 of the opcode says
        ;;; whether this is a VAR instruction or a 2OP one that happens to
        ;;; be encoded this way (which is how a 2OP gets a large constant).
        read_typed_operands(zm_fetch_byte()) -> n;
        if (op fi_&& 16:20) == 0 then
            op fi_&& 2:11111 -> idx
        else
            224 fi_+ (op fi_&& 2:11111) -> idx
        endif;
    endif;

    n;                                  ;;; the count, on top of the operands
    fast_subscrv(idx fi_+ 1, zm_ops)();
enddefine;

;;; --- running ------------------------------------------------------------

define zm_reset();
    initintvec(1024) -> zm_stack;
    0 -> zm_sp;
    ;;; The game begins in a routine that never returns; give it a frame so
    ;;; nothing has to special-case "no current frame".
    conszframe(0, false, initintvec(15), 0, 0) -> zm_frame;
    [] -> zm_frames;
    zm_initial_pc -> zm_pc;

    ;;; Tell the game what this interpreter can do.  In v3 the low bits of
    ;;; flags1 are the interpreter's answers: bit 4 clear says a status
    ;;; line IS available, bit 5 clear says no screen splitting, bit 6
    ;;; clear says a variable-pitch font is not the default.
    if zm_version fi_<= 3 then
        (zm_byte(16:01) fi_&& 2:10001111) -> zm_byte(16:01)
    endif;
    6  -> zm_byte(16:1E);       ;;; interpreter number: "IBM PC"
    `P` -> zm_byte(16:1F);      ;;; interpreter version letter

    true -> zm_running;
enddefine;

define zm_run();
    lvars steps = 0;
    while zm_running do
        zm_step();
        steps fi_+ 1 -> steps;
        if zm_max_steps and steps fi_>= zm_max_steps then
            false -> zm_running;
            mishap(steps, 1, 'zmachine: step limit reached')
        endif;
    endwhile;
    steps
enddefine;

define zm_play(story);
    lvars story;
    ;;; the game controls its own line breaks; Pop-11's automatic wrapping
    ;;; would insert its own on top of them
    dlocal poplinemax = false, poplinewidth = false;
    zm_load_story(story);
    zm_reset();
    zm_run()
enddefine;

endsection;
