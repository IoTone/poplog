/*
   Copyright Waldek Hebisch, you can distribute this file
   under terms of Free Poplog licence.
   AArch64 port by Poplog contributors.
   File:        src/arm64/ass.p
   Purpose:     Run-time assembler for AArch64 (ARM64)
   Author:      Waldek Hebisch (ARM32 original)
                 AArch64 port

   This is the runtime code generator. It generates AArch64 machine code
   IN MEMORY at runtime. Unlike genproc.p which generates assembly text
   files, ass.p writes raw 32-bit instruction encodings into memory buffers.

   Register conventions for AArch64 Poplog:
     x0-x7    : scratch / argument registers
     x9-x15   : scratch / temporaries
     x16, x17 : intra-procedure-call scratch (IP0, IP1)
     x18      : platform register (reserved)
     x19      : USP (user stack pointer)
     x20      : PB  (procedure base register)
     x21      : pop temp reg A  (pop_reg_A)
     x22      : pop temp reg B  (pop_reg_B)
     x23      : nonpop temp reg A (nonpop_reg_A)
     x24      : nonpop temp reg B (nonpop_reg_B)
     x25      : nonpop temp reg C (nonpop_reg_C)
     x28      : (spare callee-saved)
     x29      : FP (frame pointer)
     x30      : LR (link register)
     sp       : system stack pointer

   Poplog word = 8 bytes on AArch64.
   Popint tag bits = 3 (low bits).
*/


#_INCLUDE 'declare.ph'
#_INCLUDE 'vmdefs.ph'
#_INCLUDE 'external.ph'

global constant

    ;;; Assembly code subroutines referenced by user procedures

    _popenter,
    _popuenter,
    _popuncenter,
    _checkall,
    _bfield,
    _sbfield,
    _ubfield,
    _setstklen,
    _setstklen_diff,
;

constant
    procedure (
        initlongvec,
    )
;

global vars
    _trap,              ;;; interrupt flag
    pop_debugging,      ;;; <false> if optimisation pass wanted
;

section $-Sys$-Vm;

constant

    procedure (

        ;;; VM interface

        Code_pass,
        Drop_I_code,
        Get_procedure,
        Is_register,
        Trans_structure,
    ),
;

vars
    asm_clist,          ;;; list of I-code to be assembled
    asm_instr,          ;;; the current I-code instruction
    asm_struct_list,    ;;; list of items to go in the structure table
    _asm_pass,          ;;; assembly pass counter - false when dropping code
    _asm_drop_ptr,      ;;; pointer to drop code at
    _asm_code_offset,   ;;; offset into executable code (in bytes)
    _Nlocals,           ;;; number of dynamic locals
    _Npopstkvars,       ;;; number of pop on-stack lvars
    _Nstkvars,          ;;; total number of on-stack lvars
   ;;; distance between procedure start of code
    _pdr_offset,
   ;;; buffer for storing literals
   lit_buff,
   ;;; number of used positions in the literal buffer
   _lit_count,
   ;;; start position of literal pools
;
lvars
   literal_pools,
   ;;; position of first instruction needing a literal
   _current_literal_zone,
   ;;; start of current literal pool
   _current_literal_pool,
;

endsection;

;;; ---------------------------------------------------------------------

section $-Sys$-Vm;

lvars
      _regmask,
      _strsize, ;;; size of structure table in bytes
      ;;; No-flags branch state: a "compare" stashes its operands here and the
      ;;; following branch emits a single RISC-V compare-and-branch.
      _cmp_lhs = _0,
      _cmp_rhs = _0,
      _cmp_kind = "cmp",
;

lconstant

    ;;; =====================================================================
    ;;; RISC-V (rv64gc, LP64D) INSTRUCTION FIELDS
    ;;; =====================================================================
    ;;; Instructions are 32 bits; we always plant the full (uncompressed) form
    ;;; so the 4-byte stride the codegen assumes holds.  drop_* build the
    ;;; encodings via the _rv_{i,r,s,b,u,j} format helpers below.

    ;;; Opcodes
    _OP_IMM     = _16:13,       ;;; addi/slli/...   (I-type)
    _OP_REG     = _16:33,       ;;; add/sub/mul/... (R-type)
    _OP_LOAD    = _16:03,       ;;; ld/lw/lb/...    (I-type)
    _OP_STORE   = _16:23,       ;;; sd/sw/sb/...    (S-type)
    _OP_BRANCH  = _16:63,       ;;; beq/bne/blt/... (B-type)
    _OP_JAL     = _16:6F,       ;;; jal            (J-type)
    _OP_JALR    = _16:67,       ;;; jalr           (I-type)
    _OP_LUI     = _16:37,       ;;; lui            (U-type)
    _OP_AUIPC   = _16:17,       ;;; auipc          (U-type)

    ;;; funct7 selectors
    _F7_0       = _0,
    _F7_SUB     = _16:20,       ;;; sub / sra (with the OP_REG/SRA funct3)
    _F7_MULDIV  = _1,           ;;; M extension: mul/div/rem

    ;;; Register codes (RISC-V 5-bit numbers).  NB: the handlers use _X0.._X3 as
    ;;; WORKING registers (arm64 had general x0-x3 there); on RISC-V x0-x3 are
    ;;; zero/ra/sp/gp, so _X0.._X3 are remapped to the work registers a0-a3
    ;;; (x10-x13), matching genproc R0-R3.  _X4.._X31 keep their literal numbers
    ;;; (used only in the named-register / identifier definitions).
    _X0  = _10, _X1  = _11, _X2  = _12, _X3  = _13, _X4  = _4,
    _X5  = _5,  _X6  = _6,  _X7  = _7,  _X8  = _8,  _X9  = _9,
    _X10 = _10, _X11 = _11, _X12 = _12, _X13 = _13, _X14 = _14,
    _X15 = _15, _X16 = _16, _X17 = _17, _X18 = _18, _X19 = _19,
    _X20 = _20, _X21 = _21, _X22 = _22, _X23 = _23, _X24 = _24,
    _X25 = _25, _X26 = _26, _X27 = _27, _X28 = _28, _X29 = _29,
    _X30 = _30, _X31 = _31,
    _ZERO = _0,                 ;;; hard-wired zero (x0); RISC-V has no XZR/SP overlap

    ;;; Abstract condition codes (arm64-compatible values so the _cc_NOT XOR-
    ;;; negation in the handlers still works; drop_br_cond maps each to a RISC-V
    ;;; compare-and-branch).
    _cc_EQ  = _2:0000,  _cc_NE  = _2:0001,
    _cc_CS  = _2:0010,  _cc_CC  = _2:0011,      ;;; unsigned >= / <
    _cc_MI  = _2:0100,  _cc_PL  = _2:0101,      ;;; signed < 0 / >= 0 (after cmp)
    _cc_VS  = _2:0110,  _cc_VC  = _2:0111,      ;;; overflow (arith path)
    _cc_HI  = _2:1000,  _cc_LS  = _2:1001,      ;;; unsigned > / <=
    _cc_GE  = _2:1010,  _cc_LT  = _2:1011,      ;;; signed >= / <
    _cc_GT  = _2:1100,  _cc_LE  = _2:1101,      ;;; signed > / <=
    _cc_AL  = _2:1110,

    _cc_NOT = _2:0001,          ;;; XOR with this negates a condition

;

lconstant

    ;;; NAMED REGISTERS (RISC-V numbers, consistent with genproc.p)

    _SP     = _2,               ;;; hardware stack pointer (x2) -- the call frame
    _USP    = _X9,              ;;; user stack pointer (s1)
    _PB     = _X18,             ;;; procedure base register (s2)
    _LR     = _1,               ;;; link register (ra = x1)

    _ARG_REG_0  = _X10,         ;;; a0 -- subroutine arguments
    _CHAIN_REG  = _X12,         ;;; a2 -- chaining targets

    ;;; Code-generation scratch (caller-saved temporaries, not Pop registers)
    _WK     = _X30,            ;;; t5 -- intra-procedure scratch (genproc R16)
    _WK2    = _X31,            ;;; t6 -- second scratch
;

protected register constant

    ;;; REGISTER IDENTIFIERS (available to the VM).  Value = popint regnum << 1,
    ;;; plus bit 0 if a pop register.  MUST match genproc.p reglabel/regnumber.

    arg_reg_0   = _pint(_ARG_REG_0) << 1,       ;;; x10 (a0)
    arg_reg_1   = _pint(_X11) << 1,             ;;; x11 (a1)
    arg_reg_2   = _pint(_X12) << 1,             ;;; x12 (a2)

    chain_reg   = _pint(_CHAIN_REG) << 1,       ;;; x12 (a2)

    pop_reg_A    = _pint(_X19) << 1 || 1,       ;;; x19 (s3) pop register-local
    pop_reg_B    = _pint(_X20) << 1 || 1,       ;;; x20 (s4)
    nonpop_reg_A = _pint(_X21) << 1,            ;;; x21 (s5)
    nonpop_reg_B = _pint(_X22) << 1,            ;;; x22 (s6)
    nonpop_reg_C = _pint(_X23) << 1,            ;;; x23 (s7)
;

constant

    ;;; REGISTER LVARS
    asm_pop_registers = [[]],
    asm_nonpop_registers = [[]],
;
define Is_address_reg() with_nargs 1;
    Is_register()           ;;; every reg is an address reg
enddefine;


;;; === CODE-PLANTING PROCEDURES ======================================

;;; do_drop_w:
;;;     write a 32-bit instruction word to the code buffer.
;;;     On AArch64, instructions are still 32 bits (4 bytes) each,
;;;     even though data words are 64 bits.

define lconstant do_drop_w(_instr);
    lvars _instr;
    unless _asm_pass then
        _instr -> _asm_drop_ptr!(i)++ -> _asm_drop_ptr;
    endunless;
    @@(i){_asm_code_offset}++ -> _asm_code_offset;
enddefine;

define lconstant do_drop_d(_val);
    lvars _val;
    unless _asm_pass then
        _val -> _asm_drop_ptr!(w)++ -> _asm_drop_ptr;
    endunless;
    @@(w){_asm_code_offset}++ -> _asm_code_offset;
enddefine;

;;; === RISC-V instruction-format builders ============================
;;; Each returns the 32-bit encoding from its fields (verified vs objdump).
;;; B/J take a signed BYTE offset; the helper does the bit scattering.

define lconstant _rv_i(_op, _f3, _rd, _rs1, _imm);
    lvars _op, _f3, _rd, _rs1, _imm;
    _shift(_imm _bimask _16:FFF, _20) _biset _shift(_rs1, _15)
        _biset _shift(_f3, _12) _biset _shift(_rd, _7) _biset _op
enddefine;

define lconstant _rv_r(_op, _f3, _f7, _rd, _rs1, _rs2);
    lvars _op, _f3, _f7, _rd, _rs1, _rs2;
    _shift(_f7, _25) _biset _shift(_rs2, _20) _biset _shift(_rs1, _15)
        _biset _shift(_f3, _12) _biset _shift(_rd, _7) _biset _op
enddefine;

define lconstant _rv_s(_op, _f3, _rs1, _rs2, _imm);
    lvars _op, _f3, _rs1, _rs2, _imm;
    _shift(_shift(_imm, _-5) _bimask _16:7F, _25) _biset _shift(_rs2, _20)
        _biset _shift(_rs1, _15) _biset _shift(_f3, _12)
        _biset _shift(_imm _bimask _16:1F, _7) _biset _op
enddefine;

define lconstant _rv_b(_op, _f3, _rs1, _rs2, _off);
    lvars _op, _f3, _rs1, _rs2, _off;
    _shift(_shift(_off, _-12) _bimask _1, _31)
        _biset _shift(_shift(_off, _-5) _bimask _16:3F, _25)
        _biset _shift(_rs2, _20) _biset _shift(_rs1, _15)
        _biset _shift(_f3, _12)
        _biset _shift(_shift(_off, _-1) _bimask _16:F, _8)
        _biset _shift(_shift(_off, _-11) _bimask _1, _7) _biset _op
enddefine;

define lconstant _rv_u(_op, _rd, _imm20);
    lvars _op, _rd, _imm20;
    _shift(_imm20 _bimask _16:FFFFF, _12) _biset _shift(_rd, _7) _biset _op
enddefine;

define lconstant _rv_j(_op, _rd, _off);
    lvars _op, _rd, _off;
    _shift(_shift(_off, _-20) _bimask _1, _31)
        _biset _shift(_shift(_off, _-1) _bimask _16:3FF, _21)
        _biset _shift(_shift(_off, _-11) _bimask _1, _20)
        _biset _shift(_shift(_off, _-12) _bimask _16:FF, _12)
        _biset _shift(_rd, _7) _biset _op
enddefine;

;;; dump_literals: flush the pending literal pool into the code stream.  Each
;;; literal is 8 bytes; loads reach it via auipc+ld (+-2GB), so unlike arm64
;;; (LDR-literal +-1MB) the pool can sit far away.
define lconstant dump_literals();
    if _asm_pass then
        conspair(_pint(_asm_code_offset), literal_pools) -> literal_pools;
    endif;
    lvars _n = _0;
    while _n _lt _lit_count do
        do_drop_d(lit_buff!(w)[_n]);
        _n _add _1 -> _n;
    endwhile;
    if _asm_pass then
        _asm_code_offset _add _16:40000000 -> _current_literal_pool;
    else
        _int(front(literal_pools)) -> _current_literal_pool;
        back(literal_pools) -> literal_pools;
    endif;
    _0 -> _lit_count;
enddefine;

;;; drop_w: plant a 32-bit instruction, flushing the literal pool (jumping over
;;; it) if we are getting too far from pending literals.
define drop_w(_instr);
    lvars _instr;
    do_drop_w(_instr);
    if _lit_count == _0 or
       (_asm_code_offset _sub _current_literal_zone) _slt _16:70000 then
        return();
    endif;
    ;;; jump over the pool: it is _lit_count*8 bytes; the J is 4 bytes.
    lvars _off = (_lit_count _mult _2 _add _1) _mult _4;
    do_drop_w(_rv_j(_OP_JAL, _ZERO, _off));
    dump_literals();
enddefine;

;;; === RISC-V instruction planting helpers ===========================

;;; Forward-declare load_literal (defined later; used by drop_cmp_imm etc.)
weak constant procedure load_literal;

;;; drop_mov_reg: MOV = addi rd, rs, 0
define drop_mov_reg(_dst, _src);
    lvars _dst, _src;
    drop_w(_rv_i(_OP_IMM, _0, _dst, _src, _0));
enddefine;

;;; drop_add_imm: addi rd, rs, #imm
define drop_add_imm(_dst, _src, _imm);
    lvars _dst, _src, _imm;
    drop_w(_rv_i(_OP_IMM, _0, _dst, _src, _imm));
enddefine;

;;; drop_sub_imm: addi rd, rs, #-imm  (RISC-V has no subtract-immediate)
define drop_sub_imm(_dst, _src, _imm);
    lvars _dst, _src, _imm;
    drop_w(_rv_i(_OP_IMM, _0, _dst, _src, _negate(_imm)));
enddefine;

;;; drop_adr: auipc rd, 0  (rd := address of THIS instruction)
define drop_adr(_dst);
    lvars _dst;
    drop_w(_rv_u(_OP_AUIPC, _dst, _0));
enddefine;

;;; drop_add_reg: add rd, n, m
define drop_add_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_rv_r(_OP_REG, _0, _F7_0, _dst, _n, _m));
enddefine;

;;; drop_sub_reg: sub rd, n, m
define drop_sub_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_rv_r(_OP_REG, _0, _F7_SUB, _dst, _n, _m));
enddefine;

;;; drop_or_reg: ORR Xd,Xn,Xm -> or rd, n, m
define drop_or_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_rv_r(_OP_REG, _6, _F7_0, _dst, _n, _m));
enddefine;

;;; drop_blr: BLR Xn -> jalr ra, rn, 0  (call via register)
define drop_blr(_rn);
    lvars _rn;
    drop_w(_rv_i(_OP_JALR, _0, _LR, _rn, _0));
enddefine;

;;; drop_br_reg: BR Xn -> jalr x0, rn, 0  (jump via register)
define drop_br_reg(_rn);
    lvars _rn;
    drop_w(_rv_i(_OP_JALR, _0, _ZERO, _rn, _0));
enddefine;

;;; drop_ret: RET -> jalr x0, ra, 0
define drop_ret();
    drop_w(_rv_i(_OP_JALR, _0, _ZERO, _LR, _0));
enddefine;

;;; drop_ldr_reg / drop_str_reg: register (byte) offset load/store.  RISC-V has
;;; no register-offset addressing, so add the offset into the base scratch first.
define drop_ldr_reg(_rt, _rn, _rm);
    lvars _rt, _rn, _rm;
    drop_add_reg(_rm, _rn, _rm);
    drop_w(_rv_i(_OP_LOAD, _3, _rt, _rm, _0));
enddefine;
define drop_str_reg(_rt, _rn, _rm);
    lvars _rt, _rn, _rm;
    drop_add_reg(_rm, _rn, _rm);
    drop_w(_rv_s(_OP_STORE, _3, _rm, _rt, _0));
enddefine;

;;; drop_lsl_imm / drop_lsr_imm / drop_asr_imm: shift by immediate.
;;; RISC-V: slli/srli/srai rd, rs, shamt (shamt in funct7-ish bits 25:20; for
;;; rv64 the 6-bit shamt sits at bits 25:20, slli funct3=1, srli/srai funct3=5,
;;; srai sets bit 30).
define drop_lsl_imm(_dst, _src, _sh);
    lvars _dst, _src, _sh;
    drop_w(_rv_i(_OP_IMM, _1, _dst, _src, _sh _bimask _16:3F));
enddefine;
define drop_lsr_imm(_dst, _src, _sh);
    lvars _dst, _src, _sh;
    drop_w(_rv_i(_OP_IMM, _5, _dst, _src, _sh _bimask _16:3F));
enddefine;
define drop_asr_imm(_dst, _src, _sh);
    lvars _dst, _src, _sh;
    drop_w(_rv_i(_OP_IMM, _5, _dst, _src, (_sh _bimask _16:3F) _biset _16:400));
enddefine;

;;; --- No-flags compare/branch model ---------------------------------
;;; A compare stashes its operands; the following branch emits one RISC-V
;;; compare-and-branch.  _cmp_kind is "cmp" (signed/unsigned relation on the two
;;; operands) or "tst" (branch on (lhs & rhs) == 0 / != 0).

;;; drop_subs_reg: SUBS Xd,Xn,Xm -- result in Xd (unless discarded) + compare.
define drop_subs_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    unless _dst == _ZERO then
        drop_w(_rv_r(_OP_REG, _0, _F7_SUB, _dst, _n, _m));
    endunless;
    _n -> _cmp_lhs; _m -> _cmp_rhs; "cmp" -> _cmp_kind;
enddefine;

;;; drop_cmp_reg: CMP Xn,Xm
define drop_cmp_reg(_n, _m);
    lvars _n, _m;
    _n -> _cmp_lhs; _m -> _cmp_rhs; "cmp" -> _cmp_kind;
enddefine;

;;; drop_cmp_imm: CMP Xn,#imm -- materialise the immediate, then compare.
define drop_cmp_imm(_n, _imm);
    lvars _n, _imm;
    load_literal(_WK2, _imm);
    _n -> _cmp_lhs; _WK2 -> _cmp_rhs; "cmp" -> _cmp_kind;
enddefine;

;;; drop_ands_reg: ANDS Xd,Xn,Xm -- result in Xd (unless discarded) + tst.
define drop_ands_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    unless _dst == _ZERO then
        drop_w(_rv_r(_OP_REG, _7, _F7_0, _dst, _n, _m));
    endunless;
    _n -> _cmp_lhs; _m -> _cmp_rhs; "tst" -> _cmp_kind;
enddefine;

;;; drop_tst_reg: TST Xn,Xm
define drop_tst_reg(_n, _m);
    lvars _n, _m;
    _n -> _cmp_lhs; _m -> _cmp_rhs; "tst" -> _cmp_kind;
enddefine;

;;; drop_mul: MUL Xd,Xn,Xm  (M extension)
define drop_mul(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_rv_r(_OP_REG, _0, _F7_MULDIV, _dst, _n, _m));
enddefine;

;;; drop_ldr_imm / drop_str_imm: ld/sd rt, off(rn)  (12-bit signed offset)
define drop_ldr_imm(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_rv_i(_OP_LOAD, _3, _rt, _rn, _off));
enddefine;
define drop_str_imm(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_rv_s(_OP_STORE, _3, _rn, _rt, _off));
enddefine;

;;; RISC-V ld/sd already take a signed 12-bit offset, so the "soff" forms are
;;; the same as the imm forms.
define drop_ldr_soff(_rt, _rn, _off);
    drop_ldr_imm(_rt, _rn, _off);
enddefine;
define drop_str_soff(_rt, _rn, _off);
    drop_str_imm(_rt, _rn, _off);
enddefine;

;;; drop_mem_off: general load/store with a signed byte offset.
define drop_mem_off(_is_load, _rt, _rn, _off);
    lvars _is_load, _rt, _rn, _off;
    if _off _sgreq _negate(_16:800) and _off _slt _16:800 then
        if _is_load then drop_ldr_imm(_rt, _rn, _off)
        else drop_str_imm(_rt, _rn, _off) endif;
    else
        ;;; out of 12-bit range: materialise base+off in a scratch
        load_literal(_WK2, _off);
        drop_add_reg(_WK2, _rn, _WK2);
        if _is_load then drop_ldr_imm(_rt, _WK2, _0)
        else drop_str_imm(_rt, _WK2, _0) endif;
    endif;
enddefine;

define drop_load_off(_rt, _rn, _off);
    drop_mem_off(true, _rt, _rn, _off);
enddefine;

define drop_store_off(_rt, _rn, _off);
    drop_mem_off(false, _rt, _rn, _off);
enddefine;

;;; drop_push_reg: push reg on USP (pre-decrement): addi base,-8 ; sd reg,0(base)
define drop_push_reg(_reg, _base);
    lvars _reg, _base;
    drop_w(_rv_i(_OP_IMM, _0, _base, _base, _negate(_8)));
    drop_w(_rv_s(_OP_STORE, _3, _base, _reg, _0));
enddefine;

;;; drop_pop_reg: pop reg off USP (post-increment): ld reg,0(base) ; addi base,8
define drop_pop_reg(_reg, _base);
    lvars _reg, _base;
    drop_w(_rv_i(_OP_LOAD, _3, _reg, _base, _0));
    drop_w(_rv_i(_OP_IMM, _0, _base, _base, _8));
enddefine;

;;; drop_stp_pre: STP rt1,rt2,[rn,#off]!  ->  addi rn,off ; sd rt1,0(rn) ; sd rt2,8(rn)
define drop_stp_pre(_rt1, _rt2, _rn, _off);
    lvars _rt1, _rt2, _rn, _off;
    drop_w(_rv_i(_OP_IMM, _0, _rn, _rn, _off));
    drop_w(_rv_s(_OP_STORE, _3, _rn, _rt1, _0));
    drop_w(_rv_s(_OP_STORE, _3, _rn, _rt2, _8));
enddefine;

;;; drop_ldp_post: LDP rt1,rt2,[rn],#off  ->  ld rt1,0(rn) ; ld rt2,8(rn) ; addi rn,off
define drop_ldp_post(_rt1, _rt2, _rn, _off);
    lvars _rt1, _rt2, _rn, _off;
    drop_w(_rv_i(_OP_LOAD, _3, _rt1, _rn, _0));
    drop_w(_rv_i(_OP_LOAD, _3, _rt2, _rn, _8));
    drop_w(_rv_i(_OP_IMM, _0, _rn, _rn, _off));
enddefine;

;;; Check_br_range: RISC-V conditional branches reach only +-4KB (B-type 13-bit
;;; signed).  A larger target needs an invert+J relaxation (TODO -- would change
;;; the instruction count and so the multi-pass measurement); fail loudly until
;;; a real procedure needs it.
define lconstant Check_br_range(_delta);
    lvars _delta;
    ;;; On the measurement pass (_asm_pass truthy -- 0) a FORWARD branch's target
    ;;; label has not been resolved yet (I_LABEL fills its offset only when the
    ;;; label is reached later in the same pass), so _delta here is meaningless
    ;;; garbage.  Only enforce the +-4KB reach on the planting pass (_asm_pass
    ;;; false), when every label offset is final.
    returnif(_asm_pass);
    if _delta _sgreq _16:1000 or _delta _slt _negate(_16:1000) then
        mishap(_pint(_delta), 1,
            'drop_br_cond: branch target out of +-4KB range (needs relaxation)');
    endif;
enddefine;

;;; drop_br_cond: emit a conditional branch to _target_off, using the operands
;;; stashed by the preceding compare.  _cc is an abstract condition code (arm64
;;; values); _target_off is the absolute target byte offset.
;;;
;;; RISC-V B-type branches reach only +-4KB -- far too small: a single Lisp/ML
;;; reader procedure easily spans >4KB between a branch and its target.  So we
;;; ALWAYS lower to the relaxed two-instruction form
;;;     b.!cc  lhs, rhs, +8      ; skip the jump when the condition is FALSE
;;;     j      target            ; (condition true) jump -- J-type reaches +-1MB
;;; which is a FIXED 8-byte size regardless of distance, so the measure and the
;;; planting pass always agree on offsets (the whole point -- a distance-
;;; dependent size would desync the two passes for forward branches whose target
;;; is unresolved during measurement).  (>+-1MB would need auipc+jalr; not yet.)
;;; The inverted funct3 = f3 XOR 1 flips beq<->bne, blt<->bge, bltu<->bgeu.
define drop_br_cond(_cc, _target_off);
    lvars _cc, _target_off, _f3, _swap = false, _delta, _lhs, _rhs;
    if _cmp_kind == "tst" then
        ;;; and WK, lhs, rhs ; then test WK against zero
        drop_w(_rv_r(_OP_REG, _7, _F7_0, _WK, _cmp_lhs, _cmp_rhs));
        if _cc == _cc_EQ then _0 else _1 endif -> _f3;
        _WK -> _lhs; _ZERO -> _rhs;
    else
        if     _cc == _cc_EQ then _0 -> _f3;
        elseif _cc == _cc_NE then _1 -> _f3;
        elseif _cc == _cc_CS then _7 -> _f3;            ;;; bgeu (unsigned >=)
        elseif _cc == _cc_CC then _6 -> _f3;            ;;; bltu (unsigned <)
        elseif _cc == _cc_HI then _6 -> _f3; true -> _swap;   ;;; bltu, swapped
        elseif _cc == _cc_LS then _7 -> _f3; true -> _swap;   ;;; bgeu, swapped
        elseif _cc == _cc_GE then _5 -> _f3;            ;;; bge (signed >=)
        elseif _cc == _cc_LT then _4 -> _f3;            ;;; blt (signed <)
        elseif _cc == _cc_GT then _4 -> _f3; true -> _swap;   ;;; blt, swapped
        elseif _cc == _cc_LE then _5 -> _f3; true -> _swap;   ;;; bge, swapped
        elseif _cc == _cc_MI then _4 -> _f3;            ;;; blt (n-m < 0)
        elseif _cc == _cc_PL then _5 -> _f3;            ;;; bge
        else mishap(_pint(_cc), 1, 'drop_br_cond: unhandled condition code');
        endif;
        if _swap then _cmp_rhs -> _lhs; _cmp_lhs -> _rhs;
        else        _cmp_lhs -> _lhs; _cmp_rhs -> _rhs;
        endif;
    endif;
    ;;; inverted short branch over the jump (8 bytes ahead = past the J below)
    drop_w(_rv_b(_OP_BRANCH, _f3 _bixor _1, _lhs, _rhs, _8));
    ;;; unconditional J to the real target (recompute delta from the J's slot)
    _target_off _sub _asm_code_offset -> _delta;
    drop_w(_rv_j(_OP_JAL, _ZERO, _delta));
enddefine;

;;; drop_br_uncond: J to a known code offset (unconditional, +-1MB).
define drop_br_uncond(_target_off);
    lvars _target_off;
    _target_off _sub _asm_code_offset -> _target_off;
    drop_w(_rv_j(_OP_JAL, _ZERO, _target_off));
enddefine;


;;; === LITERAL LOADING ================================================

;;; load_literal: load a 64-bit value into _reg.
;;;   1. fits in a signed 12-bit immediate: addi reg, x0, val
;;;   2. fits in signed 32-bit: lui reg, hi20 ; addi reg, reg, lo12
;;;   3. otherwise: literal pool, reached via auipc reg, hi ; ld reg, lo(reg)
define load_literal(_reg, _val);
    lvars _reg, _val;
    if _val _sgreq _negate(_16:800) and _val _slt _16:800 then
        drop_w(_rv_i(_OP_IMM, _0, _reg, _ZERO, _val));
    elseif _val _sgreq _negate(_16:80000000) and _val _slt _16:80000000 then
        lvars _lo12 = _val _bimask _16:FFF;
        lvars _hi20 = _shift(_val _add _16:800, _-12) _bimask _16:FFFFF;
        drop_w(_rv_u(_OP_LUI, _reg, _hi20));
        unless _lo12 == _0 then
            drop_w(_rv_i(_OP_IMM, _0, _reg, _reg, _lo12));
        endunless;
    else
        if _lit_count == _0 then
            _asm_code_offset -> _current_literal_zone;
        endif;
        if _lit_count _lt _2048 then
            lvars _lit_pos = _shift(_lit_count, _3) _add _current_literal_pool,
                  _dist = _lit_pos _sub _asm_code_offset;
            _val -> lit_buff!(w)[_lit_count];
            _lit_count _add _1 -> _lit_count;
            lvars _lo12 = _dist _bimask _16:FFF;
            lvars _hi20 = _shift(_dist _add _16:800, _-12) _bimask _16:FFFFF;
            drop_w(_rv_u(_OP_AUIPC, _reg, _hi20));
            drop_w(_rv_i(_OP_LOAD, _3, _reg, _reg, _lo12));
        else
            mishap(0, 'load_literal: too many literals');
        endif;
    endif;
enddefine;

;;; === OPERAND ACCESS =================================================

;;; do_load_or_store:
;;;     Load from or store to an operand described by -structure-.
;;;     structure is either:
;;;       - A negative integer: offset for an on-stack lvar
;;;       - A non-negative integer: index into the procedure's structure table
;;;     defer: if true, the operand is indirect (load the pointer, then
;;;            load/store through it)

define do_load_or_store(_is_load, _reg, structure, defer, _tmp_reg);
    lvars _is_load, _reg, structure, defer, _tmp_reg;
    lvars _str = _int(structure);
    if _neg(_str) then
        ;;; Negated offset for an on-stack lvar, shifted left by 1
        ;;; Bit 0 set means access via a ref (indirect)
        unless _str _bitst _1 then false -> defer endunless;
        _negate(_shift(_str, _-1)) -> _str;
        if defer then
            drop_load_off(_tmp_reg, _SP, _str);
        else
            if _is_load then
                drop_load_off(_reg, _SP, _str);
            else
                drop_store_off(_reg, _SP, _str);
            endif;
        endif;
    else
        if _is_load or defer then
            drop_load_off(if defer then _tmp_reg else _reg endif,
                         _PB, @@PD_TABLE{_str});
        else
            mishap(0, 'store to frozen value');
        endif;
    endif;
    if defer then
        if _is_load then
            drop_load_off(_reg, _tmp_reg, _0);
        else
            drop_store_off(_reg, _tmp_reg, _0);
        endif;
    endif;
enddefine;

define get_arg(_arg);
    lvars structure;
    asm_instr!INST_ARGS[_arg] -> structure;
    if iscompound(structure) and structure >=@(w) _system_end then
        ;;; replace structure with offset or register ident on pass 0
        Trans_structure(structure) ->> structure -> asm_instr!INST_ARGS[_arg]
    endif;
    structure;
enddefine;

define load_from_arg(_arg, defer, _tmp_reg);
    lvars _arg, defer, _tmp_reg, _reg,
           structure = get_arg(_arg);
    if issimple(structure) then
        do_load_or_store(true, _tmp_reg, structure, defer, _tmp_reg);
        _tmp_reg;
    elseif Is_register(structure) ->> _reg then
        unless defer then
            mishap(0, 'REGISTER USED AS IMMEDIATE OPERAND')
        endunless;
        _int(_reg);
    else
        load_literal(_tmp_reg, structure);
        if defer then
           drop_load_off(_tmp_reg, _tmp_reg, _0);
        endif;
        _tmp_reg;
    endif;
enddefine;

define store_reg_to_arg(_reg, _arg, defer, _tmp_reg);
    lvars _reg, _arg, defer, _tmp_reg,
          structure = get_arg(_arg);
    if issimple(structure) then
        do_load_or_store(false, _reg, structure, defer, _tmp_reg);
    elseif Is_register(structure) ->> _arg then
        unless defer then
            mishap(0, 'REGISTER USED AS IMMEDIATE OPERAND')
        endunless;
        drop_mov_reg(_int(_arg), _reg);
    elseif defer then
        load_literal(_tmp_reg, structure);
        drop_store_off(_reg, _tmp_reg, _0);
    else
        mishap(0, 'store_reg_to_arg unimplemented');
    endif;
enddefine;

define store_reg(_reg);
    if asm_instr!V_LENGTH == _2 then
        drop_push_reg(_reg, _USP);
    else
        store_reg_to_arg(_reg, _1, true, _X1);
    endif;
enddefine;

define load_fsrc_to_reg(_arg, _reg);
    dlocal asm_instr;
    lvars opd = asm_instr!INST_ARGS[_arg];
    if opd then
        lvars op = opd!INST_OP;
        if op == I_MOVENUM or op == I_MOVEADDR then
            load_literal(_reg, opd!INST_ARGS[_0]);
            _reg;
        else
            opd -> asm_instr;
            load_from_arg(_0, op == I_MOVE, _reg);
        endif;
    else
        drop_pop_reg(_reg, _USP);
        _reg;
    endif;
enddefine;

;;; === TRANSLATING I-CODE INSTRUCTIONS ===============================


;;; I-code data movement instructions:

define I_POP();
    drop_pop_reg(_X0, _USP);
    store_reg_to_arg(_X0, _0, true, _X1);
enddefine;

define I_POPQ();
    drop_pop_reg(_X0, _USP);
    store_reg_to_arg(_X0, _0, false, _X1);
enddefine;

define I_STORE();
    drop_load_off(_X0, _USP, _0);
    store_reg_to_arg(_X0, _0, true, _X1);
enddefine;

define I_MOVE();
    lvars _dest_reg = false, structure;
    if asm_instr!V_LENGTH == _3 then
        get_arg(_1) -> structure;
        if Is_register(structure) ->> _dest_reg then
            _int(_dest_reg) -> _dest_reg;
        endif;
    endif;
    lvars _reg = if _dest_reg then _dest_reg else _X0 endif;
    load_from_arg(_0, true, _reg) -> _reg;
    if _reg /== _dest_reg then
        store_reg(_reg);
    endif;
enddefine;

define I_MOVEQ();
    lvars _dest_reg = false, structure;
    if asm_instr!V_LENGTH == _3 then
        get_arg(_1) -> structure;
        if Is_register(structure) ->> _dest_reg then
            _int(_dest_reg) -> _dest_reg;
        endif;
    endif;
    lvars _reg = if _dest_reg then _dest_reg else _X0 endif;
    load_from_arg(_0, false, _reg) -> _reg;
    if _reg /== _dest_reg then
        store_reg(_reg);
    endif;
enddefine;

define I_MOVES();
    ;;; Duplicate top of user stack
    drop_load_off(_X0, _USP, _0);
    drop_push_reg(_X0, _USP);
enddefine;

define Do_move_imm();
    lvars _arg1;
    asm_instr!INST_ARGS[_0] -> _arg1;
    lvars _dest_reg = false, structure;
    if asm_instr!V_LENGTH == _3 then
        get_arg(_1) -> structure;
        if Is_register(structure) ->> _dest_reg then
            _int(_dest_reg) -> _dest_reg;
        endif;
    endif;
    lvars _reg = if _dest_reg then _dest_reg else _X0 endif;
    load_literal(_reg, _arg1);
    if _reg /== _dest_reg then
        store_reg(_reg);
    endif;
enddefine;

define I_MOVENUM();
    Do_move_imm();
enddefine;

define I_MOVEADDR();
    Do_move_imm();
enddefine;

;;; Move to/from return address slot in stack frame
define I_MOVE_CALLER_RETURN();
    fast_chain(asm_instr!INST_ARGS[_2])
enddefine;

define I_PUSH_UINT();
    lvars _arg1;
    Pint_->_uint(asm_instr!INST_ARGS[_0], _-1) -> _arg1;
    load_literal(_X0, _arg1);
    drop_push_reg(_X0, _USP);
enddefine;

define I_ERASE();
    ;;; Pop and discard top of user stack: add 8 to USP
    drop_add_imm(_USP, _USP, _8);
enddefine;

define I_SWAP();
    lvars _i, _j;
    _int(asm_instr!INST_ARGS[_0]) -> _i;
    _int(asm_instr!INST_ARGS[_1]) -> _j;
    if _i _slt _0 or _j _slt _0 then
        printf(_pint(_i), '_i = %p, ');
        printf(_pint(_j), '_j = %p\n');
        mishap(0, 'I_SWAP with negative index')
    endif;
    ;;; Each slot is 8 bytes on AArch64
    lvars _ioff = _shift(_i, _3), _joff = _shift(_j, _3);
    if _ioff _slt _16:8000 and _joff _slt _16:8000 then
        drop_load_off(_X0, _USP, _ioff);
        drop_load_off(_X1, _USP, _joff);
        drop_store_off(_X0, _USP, _joff);
        drop_store_off(_X1, _USP, _ioff);
    else
        mishap(0, 'I_SWAP with too large index');
    endif;
enddefine;


/*  Standard Field Access for -conskey-, -sysFIELD_VAL- and -sysSUBSCR-  */

;;; stack_offset:
;;;     checks that -structure- refers to a direct, on-stack lvar
;;;     and returns the appropriate offset as a sysint

define constant stack_offset(/* structure */) with_nargs 1;
    lvars structure;
    if isinteger(Trans_structure(/* structure */) ->> structure)
    and structure fi_< 0
    and not(_int(structure) _bitst _1)
    then
        _negate(_shift(_int(structure), _-1));
    else
        false;
    endif;
enddefine;

;;; I-code field access instructions:

define lconstant deref_exptr(exptr, _reg, _tmp_reg);
    lvars exptr, _reg, _tmp_reg;
    fast_repeat exptr times
        drop_load_off(_tmp_reg, _reg, _0);
        _tmp_reg -> _reg;
    endrepeat
enddefine;

lconstant

    ;;; Type codes for signed fields

    t_SGN_BYTE  = t_BYTE  || t_SIGNED,
    t_SGN_SHORT = t_SHORT || t_SIGNED,
    t_SGN_INT   = t_INT   || t_SIGNED,
    t_SGN_WORD  = t_WORD  || t_SIGNED,

    ;;; Field sizes (in bytes) of the various types
    ;;; On AArch64, t_WORD is 8 bytes

    field_size = list_assoc_val(% [%
        t_BYTE,         1,
        t_SHORT,        2,
        t_INT,          4,
        t_WORD,         8,
        t_DOUBLE,       8,
        t_SGN_BYTE,     1,
        t_SGN_SHORT,    2,
        t_SGN_INT,      4,
        t_SGN_WORD,     8,
    %] %),

    ;;; Index-scale codes for the possible field sizes

    index_scale = list_assoc_val(% [%
        1,  _pint(_0),
        2,  _pint(_1),
        4,  _pint(_2),
        8,  _pint(_3),
    %] %),

;

;;; drop_field_load:
;;;     Load a field value of the given type from [Xn + offset_in_X1].
;;;     Deposits the appropriate LDR variant instruction.

define lconstant drop_field_load(_type, _dst, _base, _off_reg);
    lvars _type, _dst, _base, _off_reg, _f3;
    ;;; compute base+offset into X0, then load from 0(X0) with the right width.
    ;;; RISC-V funct3: lb=0 lh=1 lw=2 ld=3 lbu=4 lhu=5 lwu=6.
    drop_add_reg(_X0, _base, _off_reg);
    if     _type == t_BYTE then _4              ;;; lbu (unsigned byte)
    elseif _type == t_SHORT then _5             ;;; lhu
    elseif _type == t_INT then _6               ;;; lwu
    elseif _type == t_WORD or _type == t_DOUBLE then _3     ;;; ld
    elseif _type == t_SGN_BYTE then _0          ;;; lb
    elseif _type == t_SGN_SHORT then _1         ;;; lh
    elseif _type == t_SGN_INT then _2           ;;; lw
    elseif _type == t_SGN_WORD then _3          ;;; ld (sign irrelevant)
    else mishap(0, 'drop_field_load: unsupported type')
    endif -> _f3;
    drop_w(_rv_i(_OP_LOAD, _f3, _dst, _X0, _0));
enddefine;

;;; drop_field_store:
;;;     Store a field value of the given type.

define lconstant drop_field_store(_type, _src, _base, _off_reg);
    lvars _type, _src, _base, _off_reg, _f3;
    ;;; RISC-V store funct3: sb=0 sh=1 sw=2 sd=3.
    drop_add_reg(_X0, _base, _off_reg);
    if     _type == t_BYTE or _type == t_SGN_BYTE then _0
    elseif _type == t_SHORT or _type == t_SGN_SHORT then _1
    elseif _type == t_INT or _type == t_SGN_INT then _2
    elseif _type == t_WORD or _type == t_SGN_WORD or _type == t_DOUBLE then _3
    else mishap(0, 'drop_field_store: unsupported type')
    endif -> _f3;
    drop_w(_rv_s(_OP_STORE, _f3, _X0, _src, _0));
enddefine;


define lconstant load_structure_addr(structure, exptr);
    lvars structure, _reg = _X0, _disp;
    if not(structure) then
        drop_pop_reg(_reg, _USP);
    elseif stack_offset(structure) ->> _disp then
        drop_load_off(_X0, _SP, _disp);
    elseif Is_register(Trans_structure(structure)) ->> _reg then
        _int(_reg) -> _reg;
    else
        mishap(structure, 1, 'SYSTEM ERROR 1 IN load_field_addr');
    endif;
    if exptr then
        deref_exptr(exptr, _reg, _X0);
        _X0 -> _reg;
    endif;
    _reg;
enddefine;

define load_field_addr(type, structure, _size, offset, exptr);
    lvars type, structure, _size, offset, exptr;
    lvars _reg = load_structure_addr(structure, exptr), _disp,
          _tmp_reg;

    if isinteger(offset) then
        ;;; Fixed offset: convert bit offset to bytes
        ##(b){_int(offset)|1} -> _disp;
    else
        if not(offset) then
            drop_pop_reg(_X1, _USP);
        elseif stack_offset(offset) ->> _disp then
            drop_load_off(_X1, _SP, _disp);
        elseif Is_register(Trans_structure(offset)) ->> _tmp_reg then
            drop_mov_reg(_X1, _int(_tmp_reg));
        else
            mishap(offset, 1, 'SYSTEM ERROR 2 IN load_field_addr');
        endif;
        lvars _n = field_size(type);
        if _size == 1 then
            @@V_BYTES-{_int(_n)} -> _disp;
            ;;; The index in X1 is a popint = (i<<2)+3 (2-bit tag).  Recover the
            ;;; integer index i with ASR X1,X1,#2 (SBFM X1,X1,#2,#63); the
            ;;; scaled ADD below (LSL #index_scale(_n)) then multiplies by the
            ;;; field byte size, giving i*_n.  (The old code assumed a 3-bit
            ;;; tag -- using the popint directly as a byte offset for _n==8 and
            ;;; ASR #3 otherwise -- both wrong for the real 2-bit encoding.)
            drop_asr_imm(_X1, _X1, _2);
        else
            _int(_size fi_* _n) -> _size;
            @@V_BYTES-{_size} -> _disp;
            load_literal(_WK, _size);
            ;;; srai X1, X1, #2  (recover integer index from 2-bit-tagged popint)
            drop_asr_imm(_X1, _X1, _2);
            ;;; MUL X1, X1, WK
            drop_mul(_X1, _X1, _WK);
            1 -> _n;
        endif;
        ;;; ADD X0, reg, X1 {, LSL #scale}  (RISC-V: slli then add)
        lvars _scale = _int(index_scale(_n));
        if _zero(_scale) then
            drop_add_reg(_X0, _reg, _X1);
        else
            drop_lsl_imm(_X1, _X1, _scale);
            drop_add_reg(_X0, _reg, _X1);
        endif;
        _X0 -> _reg;
    endif;
    load_literal(_X1, _disp);
    drop_add_reg(_X0, _reg, _X1);
    _X0;
enddefine;

define lconstant do_bit_field(type, _size, structure, offset, upd, exptr);
    lvars _reg = load_structure_addr(structure, exptr), _disp,
         _tmp_reg;
    if _reg /== _X2 then
        drop_mov_reg(_X2, _reg);
    endif;
    if isinteger(offset) then
        load_literal(_X1, _int(offset));
    else
        if not(offset) then
            drop_pop_reg(_X1, _USP);
        elseif stack_offset(offset) ->> _disp then
            drop_load_off(_X1, _SP, _disp);
        elseif Is_register(Trans_structure(offset)) ->> _tmp_reg then
            drop_mov_reg(_X1, _int(_tmp_reg));
        else
            mishap(0, 'SYSTEM ERROR do_bit_field');
        endif;
        ;;; Recover integer offset from 2-bit-tagged popint: srai X1, X1, #2
        drop_asr_imm(_X1, _X1, _2);
        load_literal(_WK, _int(_size));
        drop_mul(_X1, _X1, _WK);
        ##(1){@@V_BYTES|b} _sub _int(_size) -> _disp;
        if not(_zero(_disp)) then
            load_literal(_WK, _disp);
            drop_add_reg(_X1, _X1, _WK);
        endif;
    endif;
    load_literal(_X0, _int(_size));
    lvars _routine = if upd then _ubfield
                     elseif type == t_BIT then _bfield
                     else _sbfield endif;
    load_literal(_WK, _routine);
    drop_blr(_WK);
enddefine;

define I_PUSH_FIELD();
    lvars type, _size, structure, offset, cvt, exptr;
    explode(asm_instr) -> exptr -> cvt -> offset -> structure ->
                       _size -> type -> ;
    if type fi_&& t_BASE_TYPE == t_BIT then
        do_bit_field(type, _size, structure, offset, false, exptr);
    else
        lvars _reg = load_field_addr(type, structure, _size, offset, exptr);
        ;;; Load the field value
        ;;; Use zero offset from computed address in X0
        load_literal(_X1, _0);
        drop_field_load(type fi_&& t_BASE_TYPE fi_|| (type fi_&& t_SIGNED),
                        _X0, _reg, _X1);
    endif;
    if cvt then
        ;;; convert raw field value to a popint: X0 = (X0 << 2) | 3
        ;;; (2-bit tag.  The old code did << 3 | 7, a 3-bit/scale-8 tag that
        ;;;  never existed -> integer fields read back as huge wrong popints,
        ;;;  which then corrupt the heap when used as indices.)
        ;;; slli X0, X0, #2
        drop_lsl_imm(_X0, _X0, _2);
        ;;; or X0, X0, X1  (X1 = 3)
        load_literal(_X1, _3);
        drop_or_reg(_X0, _X0, _X1);
    endif;
    drop_push_reg(_X0, _USP);
enddefine;

define I_POP_FIELD();
    lvars type, btype, _size, structure, offset, exptr;
    explode(asm_instr) -> exptr -> offset -> structure -> _size -> type -> ;
    if ((type fi_&& t_BASE_TYPE) ->> btype) == t_BIT then
        do_bit_field(type, _size, structure, offset, true, exptr);
        return();
    endif;
    lvars _reg = load_field_addr(type, structure, _size, offset, exptr);
    drop_pop_reg(_X1, _USP);
    ;;; Store the field value
    load_literal(_X3, _0);
    drop_field_store(btype fi_|| (type fi_&& t_SIGNED), _X1, _reg, _X3);
enddefine;

define I_PUSH_FIELD_ADDR();
    lvars type, size, structure, offset, exptr;
    explode(asm_instr) -> exptr -> offset -> structure -> size -> type -> ;
    lvars _reg = load_field_addr(type, structure, size, offset, exptr);
    drop_push_reg(_reg, _USP);
enddefine;


/*  Fast Field Access  */

;;; I-code fast field access instructions:

define I_FASTFIELD();
    lvars _offs;
    lvars _reg0 = load_fsrc_to_reg(_1, _WK);
    if asm_instr!INST_ARGS[_0] ->> _offs then
        _int(_offs) -> _offs;
    else
        drop_load_off(_X0, _reg0, @@P_FRONT);
        drop_push_reg(_X0, _USP);
        @@P_BACK -> _offs;
    endif;
    drop_load_off(_X0, _reg0, _offs);
    drop_push_reg(_X0, _USP);
enddefine;

define I_UFASTFIELD();
    lvars _reg0 = load_fsrc_to_reg(_1, _X0);
    drop_pop_reg(_X2, _USP);
    lvars _offs = _int(asm_instr!INST_ARGS[_0]);
    drop_store_off(_X2, _reg0, _offs);
enddefine;

;;; Fast vector subscript address (mirrors the x86_64 runtime VM I_FASTSUBV):
;;;   addr = vector + popint*2 + (INST_ARGS[0] - 8)
;;; The index is a 2-bit popint = (i<<2)+3; scaling it by 2 gives 8i+6, and the
;;; displacement (INST_ARGS[0] - 8) absorbs the base + the (i-1) and tag offset,
;;; landing on element i at [vector + (i-1)*8].  Verified against the measured
;;; vector layout (element i at [v + (i-1)*8]).  The OLD code used the popint
;;; directly as a byte offset (X1 + offs*8), assuming a 3-bit/scale-8 tag that
;;; never existed -- garbage for the real 2-bit popints (broke for..in_vector).
;;; (x86_64 subtracts 14 because its operand = V; arm64's operand = V-6, so -8.)

;;; Fast vector subscript byte-offset into X1, faithful port of the x86_64
;;; handler: addr = structure + popint*2 + (INST_ARGS[0] - 14).
;;; The index is a 2-bit popint = (i<<2)+3, so popint*2 = 8i+6.  INST_ARGS[0]
;;; is the byte offset to the first element and DIFFERS by subscript base:
;;; fast_subscrv (1-based) has arg 0 = 0 -> offs -14, giving (i-1)*8;
;;; fast_subscrv0 (0-based) has arg 0 = 8 -> offs -6, giving i*8.
;;; (Hardcoding -14 only worked for the 1-based case, and made 0-based writes
;;; -- e.g. chars.p's Char_name_table built via fast_subscrv0 -- land one
;;; element before the vector, corrupting the preceding heap structure.)
define lconstant fastsubv_index();
    lvars _offs = _int(asm_instr!INST_ARGS[_0]) _sub _14;
    drop_pop_reg(_X1, _USP);
    drop_add_reg(_X1, _X1, _X1);            ;;; X1 = popint*2 = 8i + 6
    if _offs _sgr _0 then
        drop_add_imm(_X1, _X1, _offs);
    elseif _offs _slt _0 then
        drop_sub_imm(_X1, _X1, _negate(_offs));
    endif;
enddefine;

define I_FASTSUBV();
    lvars _reg0 = load_fsrc_to_reg(_1, _X0);
    fastsubv_index();
    drop_ldr_reg(_X0, _X0, _X1);
    drop_push_reg(_X0, _USP);
enddefine;

define I_UFASTSUBV();
    lvars _reg0 = load_fsrc_to_reg(_1, _X0);
    fastsubv_index();
    drop_pop_reg(_X2, _USP);
    drop_str_reg(_X2, _X0, _X1);
enddefine;


/*  Fast Integer +/-  */

define I_FAST_+-_2();
    lvars opd, _is_add;
    dlocal asm_instr;
    if asm_instr!INST_ARGS[_0] then true else false endif -> _is_add;
    lvars _reg0 = load_fsrc_to_reg(_1, _X0);
    lvars _reg1 = load_fsrc_to_reg(_2, _X1);
    ;;; Remove popint tag from one operand before adding the two popints.
    ;;; popint(n) = (n<<2)+3, so the tag is 3 (2-bit), NOT 7.
    ;;;   popint(a)+popint(b) = (a+b)<<2 + 6; subtract one tag (3) to land
    ;;;   on popint(a+b) = (a+b)<<2 + 3.  (Using #7 gave popint(a+b-1).)
    drop_sub_imm(_X0, _reg0, _3);
    if _is_add then
        drop_add_reg(_X0, _reg1, _X0);
    else
        drop_sub_reg(_X0, _reg1, _X0);
    endif;
    asm_instr!INST_ARGS[_2] -> opd;
    if opd then
        opd -> asm_instr;
        store_reg_to_arg(_X0, _0, true, _X1);
    else
        drop_push_reg(_X0, _USP);
    endif;
enddefine;

define I_FAST_+-_3();
    lvars _is_add;
    if asm_instr!INST_ARGS[_0] then true else false endif -> _is_add;
    lvars _reg0 = load_fsrc_to_reg(_1, _X0);
    lvars _reg1 = load_fsrc_to_reg(_2, _X1);
    ;;; Remove popint tag (3, 2-bit) from one operand -- see I_FAST_+-_2.
    drop_sub_imm(_X0, _reg0, _3);
    if _is_add then
        drop_add_reg(_X0, _reg1, _X0);
    else
        drop_sub_reg(_X0, _reg1, _X0);
    endif;
    if asm_instr!INST_ARGS[_3] then
        store_reg_to_arg(_X0, _3, true, _X1);
    else
        drop_push_reg(_X0, _USP);
    endif;
enddefine;


/*  Branches and Tests  */

;;; I_LABEL:
;;;     called from -Code_pass- when a label is encountered in -asm_clist-

define I_LABEL();
    _pint(_asm_code_offset) -> fast_front(asm_clist);
enddefine;

;;; I_BR_std:
;;;     plant a relative branch instruction of a known size.

define I_BR_std(_broffset, _arg);
    lvars _broffset, _arg;
    drop_br_uncond(_broffset);
enddefine;

;;; I_BR:
;;;     plant an unconditional relative jump.

define I_BR(_broffset, _arg);
    lvars _broffset, _arg;
    drop_br_uncond(_broffset);
enddefine;

;;; I_BRCOND:
;;;     standard conditional branch, used as argument to I_IF_opt etc.

define I_BRCOND(_ifso, _ifnot, _is_so, _broffset, _arg);
    lvars _ifso, _ifnot, _is_so, _broffset, _arg;
    mishap(0, 'I_BRCOND unimplemented');
enddefine;

define drop_BR_cond(_ifso, _ifnot, instr);
    if instr!INST_ARGS[_2] == I_BRCOND then
        drop_br_cond(if instr!INST_ARGS[_1] then _ifso else _ifnot endif,
                     _int(fast_front(instr!INST_ARGS[_0])));
    else
        mishap(0, 'Unknown branch instruction in drop_BR_cond');
    endif;
enddefine;

;;; {I_IF_opt ^target ^is_so ^opd}
;;;     the standard test instruction: compares the operand with <false>
;;;     and jumps to -target- if the test succeeds (or fails).

define I_IF_opt();
    lvars _reg0 = load_fsrc_to_reg(_3, _X0);
    load_literal(_X1, false);
    drop_cmp_reg(_reg0, _X1);
    drop_BR_cond(_cc_NE, _cc_EQ, asm_instr);
enddefine;

;;; {I_BOOL_opt ^target ^is_so ^opd}
;;;     like I_IF_opt, but used for sysAND and sysOR.

define I_BOOL_opt();
    lvars opd = asm_instr!INST_ARGS[_3];
    if opd then
        Drop_I_code(opd);
    endif;
    ;;; Argument is on user stack
    drop_load_off(_X0, _USP, _0);
    load_literal(_X1, false);
    drop_cmp_reg(_X0, _X1);
    drop_BR_cond(_cc_NE, _cc_EQ, asm_instr);
    ;;; Erase top of stack (8 bytes on AArch64)
    drop_add_imm(_USP, _USP, _8);
enddefine;

lconstant

    ;;; Condition codes for comparison subroutines

    cmp_condition_codes = [%
        nonop _eq,      _pint(_cc_EQ),  _pint(_cc_EQ),
        nonop _neq,     _pint(_cc_NE),  _pint(_cc_NE),
        nonop _sgr,     _pint(_cc_GT),  _pint(_cc_LE),
        nonop _slteq,   _pint(_cc_LE),  _pint(_cc_GT),
        nonop _slt,     _pint(_cc_LT),  _pint(_cc_GE),
        nonop _sgreq,   _pint(_cc_GE),  _pint(_cc_LT),
    %],

;

;;; {I_IF_CMP ^cmp_routine ^opd1 ^opd2 ^I_IF_opt}
;;;     optimised comparison

define I_IF_CMP();
    lvars _reg1 = load_fsrc_to_reg(_1, _X1),
          _reg0 = load_fsrc_to_reg(_2, _X0);
    drop_cmp_reg(_reg0, _reg1);
    lvars _cc = _int(fast_front(fast_back(lmember(asm_instr!INST_ARGS[_0],
                                          cmp_condition_codes))));
    drop_BR_cond(_cc, _cc _bixor _cc_NOT, asm_instr!INST_ARGS[_3]);
enddefine;

;;; {I_IF_TAG _routine operand I_IF_opt-instr}
;;;     where _routine is _issimple or _isinteger

define I_IF_TAG();
    lvars _mod, _rm, _disp;
    lvars _reg1 = load_fsrc_to_reg(_1, _X1);
    ;;; Test tag bits. On AArch64 with 3-bit tags:
    ;;;   _issimple tests bit 0
    ;;;   _isinteger tests bit 1
    ;;; We load the mask and use TST (ANDS XZR, Xn, Xm)
    lvars _mask =
        if asm_instr!INST_ARGS[_0] == _issimple then _2:01 else _2:10 endif;
    load_literal(_X0, _mask);
    drop_tst_reg(_reg1, _X0);
    drop_BR_cond(_cc_NE, _cc_EQ, asm_instr!INST_ARGS[_2]);
enddefine;

;;; {I_SWITCH ^lablist ^elselab ^opd}
;;;     computed goto.

define I_SWITCH();
    lvars lablist, elselab, _ncases, _tabend, _offs;
    asm_instr!INST_ARGS[_0] -> lablist;
    asm_instr!INST_ARGS[_1] -> elselab;
    listlength(lablist) -> _ncases;

    ;;; Load the argument to X0.
    lvars _reg = load_fsrc_to_reg(_2, _X0);

    ;;; Compare the argument with the number of cases (both popints)
    load_literal(_X1, _ncases);
    drop_cmp_reg(_reg, _X1);

    ;;; Compute the offset from the start of the procedure code to the end
    ;;; of the jump offset table.  After this point we plant TEN 4-byte
    ;;; instructions = 40 bytes before the table:
    ;;;   b.!cc, j,                      (2 -- drop_br_cond is now the relaxed pair)
    ;;;   srai, slli,                    (2 -- popint index -> 8-byte byte offset)
    ;;;   auipc, addi,                   (2 -- drop_adr + drop_add_imm, the ADR pair)
    ;;;   add, ld,                       (2 -- drop_ldr_reg expands to add then ld)
    ;;;   add, jr                        (2 -- drop_add_reg + drop_br_reg)
    ;;; Then (_ncases + 1) * 8 bytes of 64-bit offset entries.
    ;;; (drop_br_cond is 2 instrs since branch relaxation; drop_adr is auipc+addi
    ;;; and drop_ldr_reg is add+ld -- the older "28"/"36" undercounted, landing
    ;;; the out-of-range target inside table data -> SIGILL.)  The auipc-to-table
    ;;; distance is still 24 bytes (the relaxed branch sits BEFORE the auipc).
    _asm_code_offset _add _40 _add _int((_ncases + 1) * 8) -> _tabend;

    ;;; If the argument was out of range, jump to after the table (unsigned
    ;;; comparison catches both negative and too large).  This MUST come before
    ;;; the asr/lsl below: unlike arm64 (where cmp sets flags the branch reads),
    ;;; RISC-V has no flags, so drop_br_cond re-reads the stashed operand
    ;;; REGISTERS at emit time -- scaling reg first would make the range test
    ;;; compare n*8 against ncases (so e.g. go_on with n=2 wrongly took "else").
    drop_br_cond(_cc_HI, _tabend);

    ;;; Convert the 2-bit popint index to a BYTE offset into the 8-byte table
    ;;; entries: i = popint asr 2, then i*8 = i lsl 3.  (drop_ldr_reg below is a
    ;;; plain [Xn+Xm] with NO scale, so reg must already be the byte offset.)
    ;;; srai reg, reg, #2  (recover integer index from the 2-bit-tagged popint)
    drop_asr_imm(_reg, _reg, _2);
    ;;; slli reg, reg, #3  (scale to the 8-byte table-entry byte offset)
    drop_lsl_imm(_reg, _reg, _3);

    ;;; Use X1 to index into jump offset table.
    ;;; Each table entry is 8 bytes (64-bit offset from procedure start).
    ;;; The table is planted right after the BR below.  From the ADR we plant
    ;;; three more instructions (LDR, ADD, BR) before the table, so the table
    ;;; starts 16 bytes ahead of the ADR (ADR@+0, LDR@+4, ADD@+8, BR@+12,
    ;;; table@+16) -- NOT 12.  (The old #12 pointed the base at the BR itself,
    ;;; so [base + i*8] read 4 bytes misaligned across table entries and the
    ;;; BR jumped to garbage.)
    ;;; ADR X1, table_start  (note: reg/X0 already holds the i*8 byte offset,
    ;;; and drop_ldr_reg is a plain [Xn+Xm] with no scaling).
    ;;;   LDR X1, [X1, reg]   ; load offset from table
    ;;;   ADD X1, PB, X1      ; compute absolute address
    ;;;   BR X1               ; jump

    ;;; auipc X1, 0 ; addi X1, X1, 24  ->  X1 = table address.
    ;;; SIX RISC-V instructions precede the table (auipc, addi, [add+ld from
    ;;; drop_ldr_reg], add, jr), so the table is 24 bytes ahead of the auipc --
    ;;; NOT arm64's 16 (its adr/ldr/add/br were 4 instrs).
    drop_adr(_X1);                    ;;; auipc X1, 0  (X1 = PC)
    drop_add_imm(_X1, _X1, _24);      ;;; X1 = PC + 24 = table

    ;;; ld X1, [X1 + reg]   (reg is already the i*8 byte offset; expands to
    ;;; add reg,X1,reg ; ld X1,0(reg))
    drop_ldr_reg(_X1, _X1, _reg);

    ;;; ADD X1, PB, X1  then  BR X1
    drop_add_reg(_X1, _PB, _X1);
    drop_br_reg(_X1);

    ;;; Now plant the offset table (64-bit entries):
    ;;; 0 case first (error: jumps to after the table) ...
    do_drop_d(@@PD_TABLE{_strsize _add _tabend});
    ;;; ... then all the given labels
    until lablist == [] do
        fast_front(fast_destpair(lablist) -> lablist) -> _offs;
        do_drop_d(@@PD_TABLE{_strsize _add _int(_offs)});
    enduntil;

    ;;; After the table: if there was no explicit "else" case, push the
    ;;; argument back on the stack for a following error
    unless elselab then
        ;;; Reconstruct the 2-bit popint: slli reg,reg,#2 then or with 3.
        drop_lsl_imm(_reg, _reg, _2);
        load_literal(_X1, _3);
        drop_or_reg(_reg, _reg, _X1);
        drop_push_reg(_reg, _USP);
    endunless;
enddefine;

;;; {I_PLOG_IFNOT_ATOM ^fail_label ^I_BRCOND}

define I_PLOG_IFNOT_ATOM();
    if asm_instr!INST_ARGS[_1] /== I_BRCOND then
        mishap(0, 'I_PLOG_IFNOT_ATOM with unexpected arguments');
    endif;
    ;;; RISC-V no-flags convention: _prolog_unify_atom returns a0 = 0 if the atom
    ;;; unified, non-zero if not.  Branch to -fail- when not unified.
    drop_cmp_reg(_X0, _ZERO);
    drop_br_cond(_cc_NE, _int(fast_front(asm_instr!INST_ARGS[_0])));
enddefine;

;;; {I_PLOG_TERM_SWITCH ^fail_label I_BRCOND ^var_label I_BRCOND}

define I_PLOG_TERM_SWITCH();
    if asm_instr!INST_ARGS[_1] /== I_BRCOND or
       asm_instr!INST_ARGS[_3] /== I_BRCOND then
        mishap(0, 'I_PLOG_TERM_SWITCH with unexpected arguments');
    endif;
    ;;; RISC-V no-flags convention: _prolog_term_switch / _prolog_pair_switch
    ;;; leave a0 = the DEREFED term/pair (a positive heap pointer) when matched,
    ;;; because the field-extraction emitted immediately after needs it.  They
    ;;; return a0 = 0 for an unbound var (pushed on the user stack) and a0 < 0
    ;;; for a mismatch.  So: a0 == 0 -> var_label, a0 < 0 -> fail_label, else
    ;;; fall through with a0 still holding the derefed term.
    ;;; (The earlier port clobbered a0 with the 0/+1/-1 class code, so the
    ;;; extraction read fields off address 0 -> garbage perm-var values.)
    drop_cmp_reg(_X0, _ZERO);
    drop_br_cond(_cc_EQ, _int(fast_front(asm_instr!INST_ARGS[_2])));  ;;; a0 == 0 -> var
    drop_cmp_reg(_X0, _ZERO);
    drop_br_cond(_cc_LT, _int(fast_front(asm_instr!INST_ARGS[_0])));  ;;; a0 < 0 -> fail
enddefine;


;;; I-code procedure call instructions:

define load_proc(via_ident);
    lvars via_ident, _reg;
    load_from_arg(_0, via_ident, _X0) -> _reg;
    if not(_reg == _X0) then
        drop_mov_reg(_X0, _reg);
    endif;
enddefine;

;;; On AArch64, all calls to Poplog procedures go through entry stubs.
;;; We load the procedure address into X0, then load the stub address
;;; into a scratch register and BLR to it.

define I_CALL();
    load_proc(true);
    load_literal(_WK, _popenter);
    drop_blr(_WK);
enddefine;

define I_CALLQ();
    load_proc(false);
    load_literal(_WK, _popenter);
    drop_blr(_WK);
enddefine;

define I_CALLP();
    load_proc(true);
    ;;; Load PD_EXECUTE from the procedure record
    drop_load_off(_X1, _X0, _0);
    drop_blr(_X1);
enddefine;

define I_CALLPQ();
    load_proc(false);
    drop_load_off(_X1, _X0, _0);
    drop_blr(_X1);
enddefine;

define I_CALLS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popenter);
    drop_blr(_WK);
enddefine;

define I_CALLPS();
    drop_pop_reg(_X0, _USP);
    drop_load_off(_X1, _X0, _0);
    drop_blr(_X1);
enddefine;

define I_UCALL();
    load_proc(true);
    load_literal(_WK, _popuenter);
    drop_blr(_WK);
enddefine;

define I_UCALLQ();
    load_proc(false);
    load_literal(_WK, _popuenter);
    drop_blr(_WK);
enddefine;

define I_UCALLP();
    load_proc(true);
    load_literal(_WK, _popuncenter);
    drop_blr(_WK);
enddefine;

define I_UCALLPQ();
    load_proc(false);
    load_literal(_WK, _popuncenter);
    drop_blr(_WK);
enddefine;

define I_UCALLS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popuenter);
    drop_blr(_WK);
enddefine;

define I_UCALLPS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popuncenter);
    drop_blr(_WK);
enddefine;

define I_CALLABS();
    load_literal(_X0, asm_instr!INST_ARGS[_0]);
    drop_load_off(_X1, _X0, @@PD_EXECUTE);
    drop_blr(_X1);
enddefine;

define I_CHAIN_REG();
    lvars _reg;
    if Is_register(asm_instr!INST_ARGS[_0]) ->> _reg then
        ;;; Load PD_EXECUTE and branch to it
        drop_load_off(_WK, _int(_reg), @@PD_EXECUTE);
        drop_br_reg(_WK);
    else
        mishap(0, 'I_CHAIN_REG without register unimplemented');
    endif;
enddefine;

define I_CALLSUB();
    ;;; X0 may be in use for passing arguments, so use WK (x16)
    load_literal(_WK, asm_instr!INST_ARGS[_0]);
    drop_blr(_WK);
enddefine;

define I_CHAINSUB();
    load_literal(_X0, asm_instr!INST_ARGS[_0]);
    drop_br_reg(_X0);
enddefine;

define I_CALLSUB_REG();
    lvars _addr, _reg;
    fast_front(asm_instr!INST_ARGS[_0]) -> _addr;
    if Is_register(_addr) ->> _reg then
        drop_blr(_int(_reg));
    else
        ;;; absolute address
        load_literal(_WK, _addr);
        drop_blr(_WK);
    endif;
enddefine;


/*  Procedure Entry and Exit  */

;;; I_CREATE_SF:
;;;     Create a stack frame for the current procedure.
;;;     On AArch64:
;;;       - Set PB from the return address in LR
;;;       - Save callee-saved registers (including LR)
;;;       - Save dynamic locals
;;;       - Allocate on-stack lvars

;;; I_create_sf_nreg:
;;;     count the register-locals (x19..x23) recorded in _regmask (bit = rnum-19).
define lconstant I_create_sf_nreg() -> _nreg;
    lvars _nreg = _0, _rnum = _19;
    while _rnum _slteq _23 do
        if _regmask _bitst _shift(_1, _rnum _sub _19) then _nreg _add _1 -> _nreg endif;
        _rnum _add _1 -> _rnum;
    endwhile;
enddefine;

;;; I_create_sf_flen:
;;;     frame length in words == the VM's _Nframewords / PD_FRAME_LEN
;;;     (vm_conspdr.p: ##SF_LOCALS + Nstkvars + Nlocals + Nreg - ##SF_RETURN_ADDR).
define lconstant I_create_sf_flen() -> _flen;
    lvars _flen = ##SF_LOCALS _add _Nstkvars _add _Nlocals
                    _add I_create_sf_nreg() _sub ##SF_RETURN_ADDR;
enddefine;

define I_CREATE_SF();
    lvars _offs, _rnum, _ix, _flen = I_create_sf_flen();

    ;;; --- Procedure base register: PB = the procedure record (pdr). ---
    ;;; This MUST be the first instruction planted: `adr PB, .` yields the code
    ;;; start (I_CREATE_SF is the first code instr, vm_conspdr.p), and
    ;;; _pdr_offset = (code_start - pdr) + 8, so subtracting (_pdr_offset - 8)
    ;;; gives pdr.  (The old `sub PB, LR, #..` was wrong: LR is the CALLER's
    ;;; return address, not a point inside this procedure.)
    drop_adr(_PB);
    lvars _po = _pdr_offset _sub _8;
    if _po _slt _16:1000 then
        drop_sub_imm(_PB, _PB, _po);
    else
        load_literal(_WK, _po);
        drop_sub_reg(_PB, _PB, _WK);     ;;; PB(x20) is not sp, so reg form is OK
    endif;
#_IF DEF DARWIN
    ;;; Dual-mapped heap (c_core.c): execution runs in an RX alias of the RW
    ;;; heap at canonical + 2**36, so the `adr` above yields a VIEW address.
    ;;; Canonicalise PB by clearing bit 36 -- otherwise SF_OWNER and all
    ;;; PB-relative structure access use the (non-writable) view, and the
    ;;; callstack walkers (exitfrom/caller/GC) fail to match procedures.
    ;;;     and x20, x20, #0xffffffefffffffff   (encoding verified vs clang)
    drop_w(_16:925BFA94);
#_ENDIF

    ;;; --- Allocate the whole frame in one step on the hardware sp. ---
    ;;; (frame is 16-byte multiples via the VM's STACK_ALIGN padding, so a
    ;;; single sub keeps sp 16-aligned.)
    if @@(w)[_flen] _slt _16:1000 then
        drop_sub_imm(_SP, _SP, @@(w)[_flen]);
    else
        ;;; NB drop_sub_reg encodes reg 31 as XZR not SP; >4KB runtime frames
        ;;; would need the extended-register form.  These don't occur in
        ;;; practice; fail loudly if one ever does.
        mishap(0, 'I_CREATE_SF: stack frame exceeds 4KB');
    endif;

    ;;; --- SF_OWNER (= PB) at [sp + 0]. ---
    drop_store_off(_PB, _SP, @@SF_OWNER);
    ;;; --- SF_RETURN_ADDR (= LR) at the top slot [sp + (flen-1)*8]. ---
    drop_store_off(_LR, _SP, @@(w)[_flen _sub _1]);

    ;;; --- Save the incoming register-locals into their reg slots, at
    ;;;     SF_LOCALS + Nstkvars + Nlocals + k. ---
    _Nstkvars _add _Nlocals -> _ix;
    _19 -> _rnum;
    while _rnum _slteq _23 do
        if _regmask _bitst _shift(_1, _rnum _sub _19) then
            drop_store_off(_rnum, _SP, @@SF_LOCALS[_ix]);
            _ix _add _1 -> _ix;
        endif;
        _rnum _add _1 -> _rnum;
    endwhile;

    ;;; --- Save the dynamic-locals' current (old) values into their slots. ---
    ;;; The canonical layout (which the shared `Dlocal_frame_offset`,
    ;;; procedure.p:138, and the GC frame-scan / plogcore rely on) stores
    ;;; dlocals in REVERSE PD_TABLE order: PD_TABLE[k] goes to
    ;;; SF_LOCALS[Nstkvars + (Nlocals-1-k)].  So iterate PD_TABLE forward but
    ;;; fill the slots from the top down.  (Saving forward was self-consistent
    ;;; with UNWIND so plain dlocals worked, but for a proc with >1 dlocal the
    ;;; introspection offset read the MIRRORED slot -- e.g. the exception
    ;;; handler reading pop_exception_final got a different dlocal's value and
    ;;; called it.)  Single-dlocal procs are unaffected (forward == reverse).
    @@PD_TABLE -> _offs;
    _Nstkvars _add _Nlocals _sub _1 -> _ix;
    fast_repeat _pint(_Nlocals) times
        drop_load_off(_X1, _PB, _offs);             ;;; X1 = dlocal identifier
        drop_load_off(_X0, _X1, _0);                ;;; X0 = its current idval
        drop_store_off(_X0, _SP, @@SF_LOCALS[_ix]);
        _ix _sub _1 -> _ix;
        @@(w){_offs}++ -> _offs;
    endrepeat;

    ;;; --- Initialise the POP on-stack lvars to popint 0 (= 3 with the 2-bit
    ;;;     tag; was 7, a 3-bit popint(0)); they occupy the high end of the
    ;;;     stkvar region: SF_LOCALS + (Nstkvars - Npopstkvars).
    ;;;     Non-pop on-stack lvars are left uninitialised (allocated by the sub). ---
    if _Npopstkvars _gr _0 then
        load_literal(_X0, _3);
        _Nstkvars _sub _Npopstkvars -> _ix;
        fast_repeat _pint(_Npopstkvars) times
            drop_store_off(_X0, _SP, @@SF_LOCALS[_ix]);
            _ix _add _1 -> _ix;
        endrepeat;
    endif;
enddefine;


define I_UNWIND_SF();
    lvars _offs, _rnum, _ix, _flen = I_create_sf_flen();

    ;;; Reverse I_CREATE_SF, reading every value out of its slot before
    ;;; deallocating (offset loads, so sp is invariant until the final add).

    ;;; Reload the return address (LR) from the top slot [sp + (flen-1)*8];
    ;;; the following I_RETURN ( `ret` ) uses it.
    drop_load_off(_LR, _SP, @@(w)[_flen _sub _1]);

    ;;; Restore register-locals (same slots as I_CREATE_SF saved them).
    _Nstkvars _add _Nlocals -> _ix;
    _19 -> _rnum;
    while _rnum _slteq _23 do
        if _regmask _bitst _shift(_1, _rnum _sub _19) then
            drop_load_off(_rnum, _SP, @@SF_LOCALS[_ix]);
            _ix _add _1 -> _ix;
        endif;
        _rnum _add _1 -> _rnum;
    endwhile;

    ;;; Restore the dynamic-locals' saved old values back into their idents.
    ;;; Mirror I_CREATE_SF's reverse-order layout: PD_TABLE[k] is at
    ;;; SF_LOCALS[Nstkvars + (Nlocals-1-k)].
    @@PD_TABLE -> _offs;
    _Nstkvars _add _Nlocals _sub _1 -> _ix;
    fast_repeat _pint(_Nlocals) times
        drop_load_off(_X1, _PB, _offs);             ;;; X1 = dlocal identifier
        drop_load_off(_X0, _SP, @@SF_LOCALS[_ix]);  ;;; X0 = saved value
        drop_store_off(_X0, _X1, _0);               ;;; restore idval
        _ix _sub _1 -> _ix;
        @@(w){_offs}++ -> _offs;
    endrepeat;

    ;;; Restore the caller's PB (its SF_OWNER, one frame up at [sp + flen*8]).
    drop_load_off(_PB, _SP, @@(w)[_flen]);

    ;;; Deallocate the whole frame in one step.
    if @@(w)[_flen] _slt _16:1000 then
        drop_add_imm(_SP, _SP, @@(w)[_flen]);
    else
        mishap(0, 'I_UNWIND_SF: stack frame exceeds 4KB');
    endif;
enddefine;


define I_RETURN();
    ;;; RET (returns via x30/LR)
    drop_ret();
enddefine;


/*  Miscellaneous  */

;;; {I_STACKLENGTH}
;;;     push the length of the user stack

define I_STACKLENGTH();
    load_literal(_X1, ident _userhi);
    drop_load_off(_X1, _X1, _0);
    drop_sub_reg(_X0, _X1, _USP);
    ;;; X0 = userhi - USP = byte count = items*8.  popint(items) = (items<<2)+3
    ;;; = (bytes>>1)+3 since bytes = items*8.  ASR X0,X0,#1 then ORR X0,X0,#3.
    ;;; (Old code did ORR #7, assuming a 3-bit tag with the *8 word-scale folded
    ;;;  into the tag -- wrong for the real 2-bit popint encoding.)
    drop_asr_imm(_X0, _X0, _1);       ;;; srai X0, X0, #1
    load_literal(_X3, _3);
    drop_or_reg(_X0, _X0, _X3);       ;;; or X0, X0, X3
    drop_push_reg(_X0, _USP);
enddefine;

;;; {I_SETSTACKLENGTH ^saved_stacklength ^nresults}

define I_SETSTACKLENGTH();
    lvars _nresults;
    if asm_instr!INST_ARGS[_1] ->> _nresults then
        ;;; a known number of results (a popint):
        ;;; expand code for "_setstklen" inline
        ;;; MUST compute the target into t0 (x5) and use t1 (x6) as scratch --
        ;;; the registers the hand-written _setstklen_diff (alisp.s) reads.  On
        ;;; arm64 _X2/_X3 ARE x2/x3, the same registers its .s uses, so the inline
        ;;; computed straight into them; the RISC-V remap made _X2/_X3 = x12/x13
        ;;; (a2/a3) while alisp.s was ported to t0/t1 (x5/x6).  Computing into
        ;;; _X2 here left the target in x12 but _setstklen_diff read a STALE t0
        ;;; (x5) as the fill bound -> the nil-fill loop wrote over a live heap
        ;;; object (ERROR's identifier), the wild store that blocked Lisp eval at
        ;;; defs.lsp.  t0/t1 are free here (not genproc registers; the else-branch
        ;;; _setstklen call already clobbers them).  _X5=x5=t0, _X6=x6=t1.
        lvars _reg = load_fsrc_to_reg(_0, _X5);
        ;;; Expected USP = userhi - (saved_len + nresults) items * 8 bytes.
        ;;; popints are (k<<2)+3 (2-bit tag): saved + (nresults-6) = (s+n)<<2
        ;;; = items*4, then double to items*8.  (The old #14 magic assumed a
        ;;; 3-bit tag where popint already carried the <<3 word-scale.)
        load_literal(_X6, _nresults _sub _6);
        drop_add_reg(_X5, _reg, _X6);       ;;; t0 = (saved+nresults)*4
        drop_add_reg(_X5, _X5, _X5);        ;;; t0 = (saved+nresults)*8 bytes
        load_literal(_X6, ident _userhi);
        drop_load_off(_X6, _X6, _0);
        drop_sub_reg(_X5, _X6, _X5);        ;;; t0 = userhi - 8*items (target USP)
        ;;; If USP == expected, skip the call; else call _setstklen_diff.
        ;;; RISC-V has no conditional jalr, so load WK first, then a cond branch
        ;;; that skips the jalr on the equal path.  The skip distance must clear
        ;;; the WHOLE branch + the jalr: drop_br_cond ALWAYS plants the relaxed
        ;;; 2-instr form `b.!cc +8 ; j target` (8 bytes), and drop_blr is one
        ;;; jalr (4 bytes), so the jalr sits at offset+8 and the instruction past
        ;;; it at offset+12.  Hence the EQ target is +12 (NOT +8 -- that lands ON
        ;;; the jalr and calls it anyway; with the t0 register fix above that put
        ;;; the real target in the fill bound, the USP==target case then ran the
        ;;; nil-fill loop with USP==t0, decrementing USP forever and smashing the
        ;;; heap downward).  The arm64 original used +8 because its B.EQ is a
        ;;; single 4-byte instruction; RISC-V's relaxed branch is 8 bytes.
        load_literal(_WK, _setstklen_diff);
        drop_cmp_reg(_USP, _X5);
        drop_br_cond(_cc_EQ, _asm_code_offset _add _12);
        drop_blr(_WK);
    else
        ;;; general case, simply call _setstklen
        load_literal(_WK, _setstklen);
        drop_blr(_WK);
    endif;
enddefine;

;;; {I_LISP_TRUE}
;;;     replace <false> result on top of stack by nil.

define I_LISP_TRUE();
    ;;; Replace a <false> on top of the user stack with nil; leave anything else
    ;;; untouched.  Compare top against <false>, then on NE (top /== false) skip
    ;;; the single store of nil.  TWO RISC-V-specific points:
    ;;;
    ;;; (1) The nil to be stored MUST go in a register OTHER than the compare's
    ;;; rhs (X1 = <false>).  RISC-V has no condition flags: drop_cmp_reg only
    ;;; RECORDS the operand registers and drop_br_cond re-reads them when it
    ;;; plants the branch, so any write to X1 between the cmp and the branch
    ;;; changes what is compared.  The arm64 original reused X1 for nil because
    ;;; its CMP sets NZCV immediately; doing that here made the branch test
    ;;; `top == nil` instead of `top == <false>`, so a pop11 <false> result
    ;;; (top /== nil) was never converted to nil -- it leaked into Lisp as
    ;;; #<FALSE> and read as truthy (every Lisp boolean coercion, incl. SYMBOLP,
    ;;; via the "boolean" external result type).  So load nil into WK and keep X1.
    ;;;
    ;;; (2) The skip target is +12, NOT +8: drop_br_cond plants the relaxed 8-byte
    ;;; `b.!cc +8 ; j target` form and the store (drop_store_off) is one 4-byte
    ;;; instruction after it, so the instruction past the store is at offset+12.
    ;;; (arm64 used +8 because its B.NE is a single 4-byte instruction.)
    load_literal(_X1, false);
    drop_load_off(_X0, _USP, _0);
    drop_cmp_reg(_X0, _X1);
    load_literal(_WK, nil);
    drop_br_cond(_cc_NE, _asm_code_offset _add _12);
    drop_store_off(_WK, _USP, _0);
    ;;; skip: (falls through here if not equal)
enddefine;

;;; {I_CHECK}
;;;     plant checks on backward jumps.

define I_CHECK();
    ;;; Call _checkall when the interrupt trap flag is set or the user
    ;;; stack has grown below _userlim (backward jumps are the only check
    ;;; sites inside loops, so leaving this out lets an in-loop push run
    ;;; the user stack straight down over the open segment -- including
    ;;; the code being executed -- and makes loops uninterruptable).
    ;;; RISC-V notes: drop_cmp_reg only RECORDS its operands (no flags),
    ;;; so each cmp/branch pair stays adjacent and nothing may write the
    ;;; compared registers in between; drop_br_cond plants a fixed 8-byte
    ;;; `b.!cc +8 ; j target` pair, so the first branch's skip target is
    ;;; +16 (its own 8 bytes + the second 8-byte branch) and the second
    ;;; branch's is +12 (8 + the single 4-byte JALR).
    load_literal(_WK, _checkall);
    load_literal(_X1, ident _trap);
    drop_load_off(_X1, _X1, _0);
    load_literal(_X2, ident _userlim);
    drop_load_off(_X2, _X2, _0);
    ;;; trap set: skip the userlim test, straight to the call
    drop_cmp_reg(_X1, _ZERO);
    drop_br_cond(_cc_NE, _asm_code_offset _add _16);
    ;;; _userlim <= USP means the stack is fine: skip the single call
    drop_cmp_reg(_X2, _USP);
    drop_br_cond(_cc_LS, _asm_code_offset _add _12);
    drop_blr(_WK);
    ;;; skip:
enddefine;


;;; === THE ASSEMBLER =================================================

;;; Do_consprocedure:
;;;     outputs machine code into a procedure record from pop assembler
;;;     input

define Do_consprocedure(codelist, reg_locals) -> pdr;
    lvars codelist, reg_locals, pdr, _code_offset, _size, _reg_spec;
    lvars reg, _buff, _cnt;
    dlocal _regmask, _asm_drop_ptr, _asm_pass, _strsize, _pdr_offset,
           lit_buff = initlongvec(2048), _lit_count = _0,
           _current_literal_zone = _0, _current_literal_pool = _16:80000,
           literal_pools = [];

    ;;; construct reg mask from reg_locals
    _0 -> _regmask;
    for reg in reg_locals do
                _shift(_1, _int(Is_register(reg)) _sub _19) _biset _regmask -> _regmask
    endfor;

    _regmask -> _reg_spec;


    ;;; Pass 0 -- calculate instruction offsets
    _0 ->>  _pdr_offset -> _strsize;
    Code_pass(0, codelist) -> _code_offset;
    @@(w)[_int(listlength(asm_struct_list))] -> _strsize;

    ;;; Pass 0b -- re-measure with the REAL _pdr_offset and _strsize.
    ;;; Instruction SELECTION depends on them: I_CREATE_SF plants one
    ;;; instruction when (_pdr_offset - 8) fits in a sub immediate (< 4KB)
    ;;; but two otherwise, and PB-relative displacements pick different
    ;;; load forms.  The literal-pool positions recorded here for the final
    ;;; pass must come from an IDENTICAL instruction stream, else every
    ;;; pooled LDR in the final code mis-addresses by the difference --
    ;;; observed as the ML-lexer SIGILL (trailing pool landed 4 bytes off
    ;;; for a procedure with a >4KB structure table).  Latent on ELF too,
    ;;; but only Darwin's high addresses (heap 2**39, seed 2**32) force
    ;;; pooled literals everywhere, so it WAS gated to Darwin -- on a port
    ;;; that never runs there, making it dead code and leaving the bug live.
    ;;; A large vector literal reproduces it as SIGILL.  See
    ;;; docs/bugs/aarch64-large-literal-sigill.md.
    ;;; _pdr_offset mirrors the (_asm_drop_ptr - pdr) + 8 computed below:
    ;;; drop_ptr after Get_procedure = pdr@PD_TABLE + _strsize.
    @@PD_TABLE{_strsize | b} _sub @@POPBASE _add _8 -> _pdr_offset;
    [] -> literal_pools;
    _0 -> _lit_count;
    _0 -> _current_literal_zone;
    _16:80000 -> _current_literal_pool;
    Code_pass(0, codelist) -> _code_offset;

    ;;; Now calculate total size of procedure and allocate store for it.
    ;;; The procedure record will be returned with the header and structure
    ;;; table already filled in, and with _asm_drop_ptr pointing to the
    ;;; start of the executable code section.
    @@PD_TABLE{_strsize _add _code_offset | b.r} _sub @@POPBASE -> _size;
    ;;; Add space for literals (each 8 bytes)
    _size _add _shift(_lit_count, _3) -> _size;
    Get_procedure(_size, _reg_spec) -> pdr;

    (_asm_drop_ptr _sub pdr) _add _8 -> _pdr_offset;
    _asm_drop_ptr -> _buff;
    conspair(_pint(_code_offset), literal_pools) -> literal_pools;
    rev(literal_pools) -> literal_pools;
    _0 -> _lit_count;
    _int(front(literal_pools)) -> _current_literal_pool;
    back(literal_pools) -> literal_pools;
    ;;; Final pass -- plants the code
    Code_pass(false, codelist) -> _asm_code_offset;
    ;;; invariant: the final stream must match the measured one, or the
    ;;; recorded literal-pool positions are wrong for every pooled LDR.
    if _code_offset /== _asm_code_offset then
        _extern printf('[ass-diverge] measured=%lx planted=%lx\n',
                        _code_offset, _asm_code_offset) -> ;
    endif;
    _asm_drop_ptr _sub _buff -> _cnt;
    lvars _n = _0;
    while _n _lt _lit_count do
        do_drop_d(lit_buff!(w)[_n]);
        _n _add _1 -> _n;
    endwhile;

enddefine;

endsection;     /* $-Sys$-Vm */
