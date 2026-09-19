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
;

lconstant

    ;;; =====================================================================
    ;;; AArch64 INSTRUCTION ENCODINGS
    ;;; =====================================================================
    ;;;
    ;;; All AArch64 instructions are 32 bits wide.
    ;;; Encoding reference: ARM Architecture Reference Manual for A-profile.

    ;;; --- Base opcodes (before fields are OR'd in) ---

    ;;; ADD Xd, Xn, #imm12:  1001 0001 00 <imm12> <Rn> <Rd>
    _ADD_IMM    = _16:91000000,

    ;;; SUB Xd, Xn, #imm12:  1101 0001 00 <imm12> <Rn> <Rd>
    _SUB_IMM    = _16:D1000000,

    ;;; ADDS Xd, Xn, #imm12 (sets flags): 1011 0001 00 ...
    _ADDS_IMM   = _16:B1000000,

    ;;; SUBS Xd, Xn, #imm12 (sets flags): 1111 0001 00 ...
    _SUBS_IMM   = _16:F1000000,

    ;;; ADD Xd, Xn, Xm (shifted):  1000 1011 000 <Xm> 0000 00 <Xn> <Xd>
    _ADD_REG    = _16:8B000000,

    ;;; SUB Xd, Xn, Xm (shifted):  1100 1011 000 <Xm> 0000 00 <Xn> <Xd>
    _SUB_REG    = _16:CB000000,

    ;;; ADDS Xd, Xn, Xm: 1010 1011 000 ...
    _ADDS_REG   = _16:AB000000,

    ;;; SUBS Xd, Xn, Xm: 1110 1011 000 ...
    _SUBS_REG   = _16:EB000000,

    ;;; MADD Xd, Xn, Xm, Xa: 1001 1011 000 Xm 0 Xa Xn Xd
    ;;; MUL is alias for MADD with Xa=XZR(31)
    _MADD       = _16:9B000000,

    ;;; MOV Xd, Xn is alias for ORR Xd, XZR, Xn
    ;;; ORR Xd, Xn, Xm: 1010 1010 000 Xm 0000 00 Xn Xd
    _ORR_REG    = _16:AA000000,

    ;;; ORR Xd, Xn, #imm (logical immediate - complex encoding)
    ;;; We will use MOV (register) or MOVZ/MOVK for most cases

    ;;; AND Xd, Xn, Xm: 1000 1010 000 Xm 0000 00 Xn Xd
    _AND_REG    = _16:8A000000,

    ;;; ANDS Xd, Xn, Xm (sets flags): 1110 1010 000 Xm 0000 00 Xn Xd
    _ANDS_REG   = _16:EA000000,

    ;;; MVN Xd, Xm is alias for ORN Xd, XZR, Xm
    ;;; ORN Xd, Xn, Xm: 1010 1010 001 Xm 0000 00 Xn Xd
    _ORN_REG    = _16:AA200000,

    ;;; TST Xn, Xm is alias for ANDS XZR, Xn, Xm
    ;;; (We build TST from ANDS with Rd=XZR=31)

    ;;; MOVZ Xd, #imm16, LSL #shift
    ;;; 1 10 100101 hw imm16 Rd
    _MOVZ       = _16:D2800000,

    ;;; MOVK Xd, #imm16, LSL #shift
    ;;; 1 11 100101 hw imm16 Rd
    _MOVK       = _16:F2800000,

    ;;; MOVN Xd, #imm16  (move wide with NOT)
    ;;; 1 00 100101 hw imm16 Rd
    _MOVN       = _16:92800000,

    ;;; --- Load/Store instructions ---

    ;;; LDR Xt, [Xn, #imm12*8]:  1111 1001 01 imm12 Rn Rt
    _LDR_IMM    = _16:F9400000,

    ;;; STR Xt, [Xn, #imm12*8]:  1111 1001 00 imm12 Rn Rt
    _STR_IMM    = _16:F9000000,

    ;;; LDR Xt, [Xn, #simm9]! (pre-index): 1111 1000 010 simm9 11 Rn Rt
    _LDR_PRE    = _16:F8400C00,

    ;;; STR Xt, [Xn, #simm9]! (pre-index): 1111 1000 000 simm9 11 Rn Rt
    _STR_PRE    = _16:F8000C00,

    ;;; LDR Xt, [Xn], #simm9 (post-index): 1111 1000 010 simm9 01 Rn Rt
    _LDR_POST   = _16:F8400400,

    ;;; STR Xt, [Xn], #simm9 (post-index): 1111 1000 000 simm9 01 Rn Rt
    _STR_POST   = _16:F8000400,

    ;;; LDR Xt, [Xn, Xm]:  1111 1000 011 Xm 011 0 10 Xn Xt
    ;;; (register offset, UNSCALED -- S=0: plain [Xn + Xm], byte offset.
    ;;; Verified against clang: scaled LSL#3 would be F8607800.)
    _LDR_REG    = _16:F8606800,

    ;;; STR Xt, [Xn, Xm]:  1111 1000 001 Xm 011 0 10 Xn Xt
    _STR_REG    = _16:F8206800,

    ;;; LDR Xt, [Xn, Xm, SXTW]: register offset sign-extended word
    ;;; TODO: verify encoding if needed

    ;;; LDRB Wt, [Xn, #imm12]:  0011 1001 01 imm12 Rn Rt
    _LDRB_IMM   = _16:39400000,

    ;;; STRB Wt, [Xn, #imm12]:  0011 1001 00 imm12 Rn Rt
    _STRB_IMM   = _16:39000000,

    ;;; LDRH Wt, [Xn, #imm12*2]: 0111 1001 01 imm12 Rn Rt
    _LDRH_IMM   = _16:79400000,

    ;;; STRH Wt, [Xn, #imm12*2]: 0111 1001 00 imm12 Rn Rt
    _STRH_IMM   = _16:79000000,

    ;;; LDR Wt, [Xn, #imm12*4] (32-bit): 1011 1001 01 imm12 Rn Rt
    _LDRW_IMM   = _16:B9400000,

    ;;; STR Wt, [Xn, #imm12*4] (32-bit): 1011 1001 00 imm12 Rn Rt
    _STRW_IMM   = _16:B9000000,

    ;;; LDRSB Xt, [Xn, #imm12]:  0011 1001 10 imm12 Rn Rt
    _LDRSB_IMM  = _16:39800000,

    ;;; LDRSH Xt, [Xn, #imm12*2]: 0111 1001 10 imm12 Rn Rt
    _LDRSH_IMM  = _16:79800000,

    ;;; LDRSW Xt, [Xn, #imm12*4]: 1011 1001 10 imm12 Rn Rt
    _LDRSW_IMM  = _16:B9800000,

    ;;; STP Xt1, Xt2, [Xn, #imm7*8]! (pre-index):
    ;;; 1010 1001 11 imm7 Rt2 Rn Rt1
    _STP_PRE    = _16:A9800000,

    ;;; LDP Xt1, Xt2, [Xn], #imm7*8 (post-index):
    ;;; 1010 1000 11 imm7 Rt2 Rn Rt1
    _LDP_POST   = _16:A8C00000,

    ;;; STP Xt1, Xt2, [Xn, #imm7*8] (signed offset):
    ;;; 1010 1001 00 imm7 Rt2 Rn Rt1
    _STP_OFF    = _16:A9000000,

    ;;; LDP Xt1, Xt2, [Xn, #imm7*8] (signed offset):
    ;;; 1010 1001 01 imm7 Rt2 Rn Rt1
    _LDP_OFF    = _16:A9400000,

    ;;; --- Branch instructions ---

    ;;; B imm26:  0001 01 imm26
    _B          = _16:14000000,

    ;;; BL imm26: 1001 01 imm26
    _BL         = _16:94000000,

    ;;; BR Xn:  1101 0110 0001 1111 0000 00 Rn 0000 0
    _BR         = _16:D61F0000,

    ;;; BLR Xn: 1101 0110 0011 1111 0000 00 Rn 0000 0
    _BLR        = _16:D63F0000,

    ;;; RET {Xn}: 1101 0110 0101 1111 0000 00 Rn 0000 0
    ;;; Default Xn=x30
    _RET_INSTR  = _16:D65F03C0,

    ;;; B.cond imm19:  0101 0100 imm19 0 cond
    _B_COND     = _16:54000000,

    ;;; CBZ Xt, imm19:  1011 0100 imm19 Rt
    _CBZ        = _16:B4000000,

    ;;; CBNZ Xt, imm19: 1011 0101 imm19 Rt
    _CBNZ       = _16:B5000000,

    ;;; --- Comparison ---

    ;;; CMP Xn, #imm is alias for SUBS XZR, Xn, #imm
    ;;; CMP Xn, Xm is alias for SUBS XZR, Xn, Xm

    ;;; --- Bit manipulation ---

    ;;; LSL Xd, Xn, Xm: 1001 1010 110 Xm 0010 00 Xn Xd
    _LSL_REG    = _16:9AC02000,

    ;;; LSR Xd, Xn, Xm: 1001 1010 110 Xm 0010 01 Xn Xd
    _LSR_REG    = _16:9AC02400,

    ;;; ASR Xd, Xn, Xm: 1001 1010 110 Xm 0010 10 Xn Xd
    _ASR_REG    = _16:9AC02800,

    ;;; --- Shift by immediate ---
    ;;; LSL Xd, Xn, #shift is alias for UBFM
    ;;; LSR Xd, Xn, #shift is alias for UBFM
    ;;; ASR Xd, Xn, #shift is alias for SBFM
    ;;; UBFM Xd, Xn, #immr, #imms: 1101 0011 01 immr imms Xn Xd
    _UBFM       = _16:D3400000,
    ;;; SBFM Xd, Xn, #immr, #imms: 1001 0011 01 immr imms Xn Xd
    _SBFM       = _16:93400000,

    ;;; --- NOP ---
    _NOP        = _16:D503201F,

    ;;; Register codes (AArch64 uses 5-bit register numbers)

    _X0     = _0,
    _X1     = _1,
    _X2     = _2,
    _X3     = _3,
    _X4     = _4,
    _X5     = _5,
    _X6     = _6,
    _X7     = _7,
    _X8     = _8,
    _X9     = _9,
    _X10    = _10,
    _X11    = _11,
    _X12    = _12,
    _X13    = _13,
    _X14    = _14,
    _X15    = _15,
    _X16    = _16,
    _X17    = _17,
    _X18    = _18,
    _X19    = _19,
    _X20    = _20,
    _X21    = _21,
    _X22    = _22,
    _X23    = _23,
    _X24    = _24,
    _X25    = _25,
    _X26    = _26,
    _X27    = _27,
    _X28    = _28,
    _X29    = _29,
    _X30    = _30,
    _XZR    = _31,       ;;; zero register (also SP in some encodings)

    ;;; Condition codes (4-bit, same as ARM32)

    _cc_EQ  = _2:0000,          ;;; equal (Z=1)
    _cc_NE  = _2:0001,          ;;; not equal (Z=0)
    _cc_CS  = _2:0010,          ;;; carry set / unsigned >= (HS)
    _cc_CC  = _2:0011,          ;;; carry clear / unsigned < (LO)
    _cc_MI  = _2:0100,          ;;; minus / negative
    _cc_PL  = _2:0101,          ;;; plus / positive or zero
    _cc_VS  = _2:0110,          ;;; overflow
    _cc_VC  = _2:0111,          ;;; no overflow
    _cc_HI  = _2:1000,          ;;; unsigned greater-than
    _cc_LS  = _2:1001,          ;;; unsigned less-than-or-equal
    _cc_GE  = _2:1010,          ;;; signed greater-than-or-equal
    _cc_LT  = _2:1011,          ;;; signed less-than
    _cc_GT  = _2:1100,          ;;; signed greater-than
    _cc_LE  = _2:1101,          ;;; signed less-than-or-equal
    _cc_AL  = _2:1110,          ;;; always

    ;;; Condition-code mask

    _cc_NOT = _2:0001,          ;;; XOR with this negates a condition

;

lconstant

    ;;; NAMED REGISTERS

    _SP     = _31,              ;;; the HARDWARE stack pointer (reg 31 == SP in
                                ;;; the load/store + add/sub-immediate forms used
                                ;;; for frames).  The procedure CALL FRAME lives
                                ;;; here, SEPARATE from x19 (the Pop value stack,
                                ;;; _USP).  I_CREATE_SF/I_UNWIND_SF now plant the
                                ;;; genproc.p frame contract (SF_OWNER@[sp+0],
                                ;;; SF_RETURN_ADDR@top, single sub sp).  NB the
                                ;;; >4KB-frame paths would need extended-register
                                ;;; sub/add (reg 31 is XZR there, not SP); those
                                ;;; mishap for now.

    _USP    = _X19,             ;;; user stack pointer (x19)
    _PB     = _X20,             ;;; procedure base register (x20)
    _LR     = _X30,             ;;; link register

    _ARG_REG_0  = _X0,         ;;; for arguments to subroutines
    _CHAIN_REG  = _X2,         ;;; for targets of chaining

    ;;; Scratch register for code generation (IP0)
    _WK     = _X16,            ;;; intra-procedure scratch
    _WK2    = _X17,            ;;; second intra-procedure scratch
;

protected register constant

    ;;; REGISTER IDENTIFIERS
    ;;; (available to the VM)

    ;;; The value is a popint register number shifted left 1
    ;;; plus bit 0 if pop reg

    arg_reg_0   = _pint(_ARG_REG_0) << 1,       ;;; X0
    arg_reg_1   = _pint(_X1) << 1,
    arg_reg_2   = _pint(_X2) << 1,

    chain_reg   = _pint(_CHAIN_REG) << 1,       ;;; X2

    pop_reg_A    = _pint(_X21) << 1 || 1,
    pop_reg_B    = _pint(_X22) << 1 || 1,
    nonpop_reg_A = _pint(_X23) << 1,
    nonpop_reg_B = _pint(_X24) << 1,
    nonpop_reg_C = _pint(_X25) << 1,
;

constant

    ;;; REGISTER LVARS

    asm_pop_registers = [[]],
    ;;; asm_pop_registers = [%[], ident pop_reg_A, ident pop_reg_B %],
    asm_nonpop_registers = [[]],
    ;;; asm_nonpop_registers = [%[], ident nonpop_reg_A, ident nonpop_reg_B,
    ;;;                             ident nonpop_reg_C %],
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
        ;;; only output the data on the last pass
        _instr -> _asm_drop_ptr!(i)++ -> _asm_drop_ptr;
    endunless;
    @@(i){_asm_code_offset}++ -> _asm_code_offset;
enddefine;

;;; do_drop_d:
;;;     write a 64-bit data word to the code buffer (for literal pools).
;;;     Literals on AArch64 are 64-bit since pointers are 64-bit.

define lconstant do_drop_d(_val);
    lvars _val;
    unless _asm_pass then
        _val -> _asm_drop_ptr!(w)++ -> _asm_drop_ptr;
    endunless;
    @@(w){_asm_code_offset}++ -> _asm_code_offset;
enddefine;

;;; dump_literals:
;;;     flush the literal pool into the code stream.
;;;     On AArch64, each literal is 8 bytes (64-bit pointer/value),
;;;     and the LDR (literal) instruction has a +/-1MB range (19-bit signed
;;;     offset * 4).  We dump when we get close to the limit.


define lconstant dump_literals();
    if _asm_pass then
        conspair(_pint(_asm_code_offset), literal_pools)
            -> literal_pools;
    endif;
    lvars _n = _0;
    while _n _lt _lit_count do
        do_drop_d(lit_buff!(w)[_n]);
        _n _add _1 -> _n;
    endwhile;
    if _asm_pass then
        ;;; On AArch64, LDR (literal) has +/-1MB range.
        ;;; We use a conservative limit of 512KB (0x80000).
        _asm_code_offset _add _16:80000 -> _current_literal_pool;
    else
        _int(front(literal_pools)) -> _current_literal_pool;
        back(literal_pools) -> literal_pools;
        ;;; invariant: a mid-code pool must land exactly where pass 0
        ;;; recorded it, or the LDRs computed against the recorded position
        ;;; read garbage.  This check used to be Darwin-only; the invariant
        ;;; is not platform-specific and neither is the damage when it
        ;;; breaks, so it now runs everywhere.  See
        ;;; docs/bugs/aarch64-large-literal-sigill.md.
        if _current_literal_pool /== _asm_code_offset then
            _extern printf('[pool-diverge] recorded=%lx actual=%lx\n',
                            _current_literal_pool, _asm_code_offset) -> ;
        endif;
    endif;
    _0 -> _lit_count;
enddefine;

;;; drop_w:
;;;     plant a 32-bit instruction, possibly flushing the literal pool
;;;     if we are getting too far from pending literals.

define drop_w(_instr);
    lvars _instr;
    do_drop_w(_instr);
    if _lit_count == _0 or
       (_asm_code_offset _sub _current_literal_zone) _slt _16:70000 then
        return();
    endif;
    ;;; Need to skip over the literal pool: plant an unconditional branch.
    ;;; Each literal is 8 bytes, branch is 4 bytes.
    ;;; offset (in 4-byte instructions) = 1 + _lit_count * 2
    lvars _off = _lit_count * 2 + 1;
    do_drop_w(_B _biset (_off _bimask _16:3FFFFFF));
    dump_literals();
enddefine;

;;; === AArch64 instruction planting helpers ============================

;;; drop_mov_reg:
;;;     MOV Xd, Xn  (alias for ORR Xd, XZR, Xn)
define drop_mov_reg(_dst, _src);
    lvars _dst, _src;
    drop_w(_ORR_REG _biset _shift(_src, _16) _biset _shift(_XZR, _5)
                    _biset _dst);
enddefine;

;;; drop_add_imm:
;;;     ADD Xd, Xn, #imm12
define drop_add_imm(_dst, _src, _imm);
    lvars _dst, _src, _imm;
    drop_w(_ADD_IMM _biset _shift(_imm _bimask _16:FFF, _10)
                    _biset _shift(_src, _5) _biset _dst);
enddefine;

;;; drop_sub_imm:
;;;     SUB Xd, Xn, #imm12
define drop_sub_imm(_dst, _src, _imm);
    lvars _dst, _src, _imm;
    drop_w(_SUB_IMM _biset _shift(_imm _bimask _16:FFF, _10)
                    _biset _shift(_src, _5) _biset _dst);
enddefine;

;;; drop_adr:
;;;     ADR Xd, .   (Xd := address of THIS instruction; PC-relative offset 0)
;;;     Encoding: 0001 0000 immlo(0) 10000 immhi(0) Rd  ==  0x10000000 | Rd
define drop_adr(_dst);
    lvars _dst;
    drop_w(_16:10000000 _biset _dst);
enddefine;

;;; drop_add_reg:
;;;     ADD Xd, Xn, Xm
define drop_add_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_ADD_REG _biset _shift(_m, _16) _biset _shift(_n, _5) _biset _dst);
enddefine;

;;; drop_sub_reg:
;;;     SUB Xd, Xn, Xm
define drop_sub_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_SUB_REG _biset _shift(_m, _16) _biset _shift(_n, _5) _biset _dst);
enddefine;

;;; drop_subs_reg:
;;;     SUBS Xd, Xn, Xm  (sets flags; Xd=XZR for CMP)
define drop_subs_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_SUBS_REG _biset _shift(_m, _16) _biset _shift(_n, _5) _biset _dst);
enddefine;

;;; drop_cmp_reg:
;;;     CMP Xn, Xm  (alias for SUBS XZR, Xn, Xm)
define drop_cmp_reg(_n, _m);
    lvars _n, _m;
    drop_subs_reg(_XZR, _n, _m);
enddefine;

;;; drop_cmp_imm:
;;;     CMP Xn, #imm12  (alias for SUBS XZR, Xn, #imm12)
define drop_cmp_imm(_n, _imm);
    lvars _n, _imm;
    drop_w(_SUBS_IMM _biset _shift(_imm _bimask _16:FFF, _10)
                     _biset _shift(_n, _5) _biset _XZR);
enddefine;

;;; drop_tst_imm:
;;;     TST Xn, #imm  -- logical immediate form
;;;     For simple bit patterns we use ANDS XZR, Xn, Xm with Xm loaded
;;;     with the test value, since logical immediates have complex encoding.
;;;     For single-bit tests we can sometimes use TBNZ/TBZ instead.

;;; drop_ands_reg:
;;;     ANDS Xd, Xn, Xm (sets flags)
define drop_ands_reg(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_ANDS_REG _biset _shift(_m, _16) _biset _shift(_n, _5)
                     _biset _dst);
enddefine;

;;; drop_tst_reg:
;;;     TST Xn, Xm  (alias for ANDS XZR, Xn, Xm)
define drop_tst_reg(_n, _m);
    lvars _n, _m;
    drop_ands_reg(_XZR, _n, _m);
enddefine;

;;; drop_mul:
;;;     MUL Xd, Xn, Xm  (alias for MADD Xd, Xn, Xm, XZR)
define drop_mul(_dst, _n, _m);
    lvars _dst, _n, _m;
    drop_w(_MADD _biset _shift(_m, _16)
                 _biset _shift(_XZR, _10)
                 _biset _shift(_n, _5) _biset _dst);
enddefine;

;;; drop_ldr_imm:
;;;     LDR Xt, [Xn, #pimm]  (unsigned offset, scaled by 8)
;;;     pimm must be a non-negative multiple of 8, max 32760
define drop_ldr_imm(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_LDR_IMM _biset _shift(_shift(_off, _-3) _bimask _16:FFF, _10)
                    _biset _shift(_rn, _5) _biset _rt);
enddefine;

;;; drop_str_imm:
;;;     STR Xt, [Xn, #pimm]  (unsigned offset, scaled by 8)
define drop_str_imm(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_STR_IMM _biset _shift(_shift(_off, _-3) _bimask _16:FFF, _10)
                    _biset _shift(_rn, _5) _biset _rt);
enddefine;

;;; drop_ldr_reg:
;;;     LDR Xt, [Xn, Xm]   (UNSCALED register offset -- Xm is a BYTE offset)
define drop_ldr_reg(_rt, _rn, _rm);
    lvars _rt, _rn, _rm;
    drop_w(_LDR_REG _biset _shift(_rm, _16) _biset _shift(_rn, _5)
                    _biset _rt);
enddefine;

;;; drop_str_reg:
;;;     STR Xt, [Xn, Xm, LSL #3]
define drop_str_reg(_rt, _rn, _rm);
    lvars _rt, _rn, _rm;
    drop_w(_STR_REG _biset _shift(_rm, _16) _biset _shift(_rn, _5)
                    _biset _rt);
enddefine;

;;; drop_ldr_soff:
;;;     LDR Xt, [Xn, #simm9] (signed unscaled offset, using LDUR)
;;;     LDUR Xt, [Xn, #simm9]: 1111 1000 010 simm9 00 Rn Rt
define drop_ldr_soff(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_16:F8400000 _biset _shift(_off _bimask _16:1FF, _12)
                        _biset _shift(_rn, _5) _biset _rt);
enddefine;

;;; drop_str_soff:
;;;     STUR Xt, [Xn, #simm9]: 1111 1000 000 simm9 00 Rn Rt
define drop_str_soff(_rt, _rn, _off);
    lvars _rt, _rn, _off;
    drop_w(_16:F8000000 _biset _shift(_off _bimask _16:1FF, _12)
                        _biset _shift(_rn, _5) _biset _rt);
enddefine;

;;; Forward-declare load_literal: it's defined later but referenced here.
weak constant procedure load_literal;

;;; drop_mem_off:
;;;     General load/store with signed offset.
;;;     For non-negative multiples of 8 within range, uses unsigned-offset form.
;;;     Otherwise uses LDUR/STUR (signed unscaled, 9-bit range).

define drop_mem_off(_is_load, _rt, _rn, _off);
    lvars _is_load, _rt, _rn, _off;
    if _off _sgreq _0 and not(_off _bitst _7)
       and _off _slt _16:8000 then
        ;;; Positive, 8-byte aligned, fits in 12-bit unsigned offset
        if _is_load then
            drop_ldr_imm(_rt, _rn, _off);
        else
            drop_str_imm(_rt, _rn, _off);
        endif;
    elseif _off _sgreq _-256 and _off _slt _256 then
        ;;; Fits in 9-bit signed unscaled offset
        if _is_load then
            drop_ldr_soff(_rt, _rn, _off);
        else
            drop_str_soff(_rt, _rn, _off);
        endif;
    else
        ;;; Out of range for simple addressing: load offset into scratch
        load_literal(_WK2, _off);
        if _is_load then
            drop_ldr_reg(_rt, _rn, _WK2);
        else
            drop_str_reg(_rt, _rn, _WK2);
        endif;
    endif;
enddefine;

define drop_load_off(_rt, _rn, _off);
    drop_mem_off(true, _rt, _rn, _off);
enddefine;

define drop_store_off(_rt, _rn, _off);
    drop_mem_off(false, _rt, _rn, _off);
enddefine;

;;; drop_push_reg:
;;;     STR Xt, [Xn, #-8]!  (pre-decrement push)
define drop_push_reg(_reg, _base);
    lvars _reg, _base;
    ;;; STR Xt, [Xn, #-8]! = F8000000 | ((-8 & 0x1FF) << 12) | (0x3 << 10) | (Rn << 5) | Rt
    ;;; simm9 for -8 = 0x1F8
    drop_w(_STR_PRE _biset _shift(_16:1F8, _12) _biset _shift(_base, _5)
                    _biset _reg);
enddefine;

;;; drop_pop_reg:
;;;     LDR Xt, [Xn], #8  (post-increment pop)
define drop_pop_reg(_reg, _base);
    lvars _reg, _base;
    ;;; LDR Xt, [Xn], #8 = F8400400 | ((8 & 0x1FF) << 12) | (Rn << 5) | Rt
    drop_w(_LDR_POST _biset _shift(_8, _12) _biset _shift(_base, _5)
                     _biset _reg);
enddefine;

;;; drop_stp_pre:
;;;     STP Xt1, Xt2, [Xn, #imm]!
;;;     imm must be a signed multiple of 8, range -512..504
define drop_stp_pre(_rt1, _rt2, _rn, _off);
    lvars _rt1, _rt2, _rn, _off;
    lvars _imm7 = _shift(_off, _-3) _bimask _16:7F;
    drop_w(_STP_PRE _biset _shift(_imm7, _15) _biset _shift(_rt2, _10)
                    _biset _shift(_rn, _5) _biset _rt1);
enddefine;

;;; drop_ldp_post:
;;;     LDP Xt1, Xt2, [Xn], #imm
define drop_ldp_post(_rt1, _rt2, _rn, _off);
    lvars _rt1, _rt2, _rn, _off;
    lvars _imm7 = _shift(_off, _-3) _bimask _16:7F;
    drop_w(_LDP_POST _biset _shift(_imm7, _15) _biset _shift(_rt2, _10)
                     _biset _shift(_rn, _5) _biset _rt1);
enddefine;

;;; drop_br_cond:
;;;     B.cond to a known code offset.
;;;     _cc is the condition code (4 bits).
;;;     _target_off is the target code offset (absolute, in bytes from
;;;     procedure code start).

define drop_br_cond(_cc, _target_off);
    lvars _cc, _target_off;
    _target_off _sub _asm_code_offset -> _target_off;
    ;;; offset is in bytes, instruction encodes offset/4 in 19 bits
    lvars _imm19 = _shift(_target_off, _-2) _bimask _16:7FFFF;
    drop_w(_B_COND _biset _shift(_imm19, _5) _biset _cc);
enddefine;

;;; drop_br_uncond:
;;;     B to a known code offset (unconditional).
define drop_br_uncond(_target_off);
    lvars _target_off;
    _target_off _sub _asm_code_offset -> _target_off;
    lvars _imm26 = _shift(_target_off, _-2) _bimask _16:3FFFFFF;
    drop_w(_B _biset _imm26);
enddefine;


;;; === LITERAL LOADING ================================================

;;; load_literal:
;;;     Load a 64-bit value into register _reg.
;;;     Strategy:
;;;       1. If value fits in 16 bits: MOVZ
;;;       2. If value is a small negative: MOVN
;;;       3. Otherwise: load from the literal pool via LDR (literal)
;;;
;;;     On AArch64, LDR (literal) loads a 64-bit value from a PC-relative
;;;     address, encoded as a 19-bit signed offset * 4 (+/-1MB range).
;;;     LDR Xt, label: 0101 1000 imm19 Rt

define load_literal(_reg, _val);
    lvars _reg, _val;
    if _val _sgreq _0 and _val _slt _16:10000 then
        ;;; fits in MOVZ Xd, #imm16
        drop_w(_MOVZ _biset _shift(_val, _5) _biset _reg);
    elseif _val _slt _0 and _val _sgreq _-16:10000 then
        ;;; MOVN Xd, #(~val)
        lvars _nimm = _negate(_val) _sub _1;
        drop_w(_MOVN _biset _shift(_nimm _bimask _16:FFFF, _5) _biset _reg);
    elseif _val _sgreq _0 and _val _slt _16:100000000 then
        ;;; Fits in two MOVZ/MOVK instructions (32-bit positive)
        drop_w(_MOVZ _biset _shift(_val _bimask _16:FFFF, _5) _biset _reg);
        lvars _hi = _shift(_val, _-16) _bimask _16:FFFF;
        if _nonzero(_hi) then
            ;;; MOVK Xd, #imm16, LSL #16: hw=1 so bit 21 set
            drop_w(_MOVK _biset _shift(_1, _21) _biset _shift(_hi, _5)
                         _biset _reg);
        endif;
    else
        ;;; Use literal pool
        if _lit_count == _0 then
            _asm_code_offset -> _current_literal_zone;
        endif;
        if _lit_count _lt _2048 then
            ;;; Compute distance from current instruction to literal in pool.
            ;;; Each literal is 8 bytes. Pool starts at _current_literal_pool.
            lvars _lit_pos = _shift(_lit_count, _3) _add _current_literal_pool,
                  _dist = _lit_pos _sub _asm_code_offset;
            if _dist _sgreq _16:100000 then
                mishap(0, 'load_literal: distance to literal pool too large');
            else
                _val -> lit_buff!(w)[_lit_count];
                _lit_count _add _1 -> _lit_count;
                ;;; LDR Xt, label: 01 011 000 imm19 Rt
                lvars _imm19 = _shift(_dist, _-2) _bimask _16:7FFFF;
                drop_w(_16:58000000 _biset _shift(_imm19, _5) _biset _reg);
            endif;
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
    lvars _type, _dst, _base, _off_reg;
    ;;; For simplicity, compute base+offset into X0, then load from [X0]
    drop_add_reg(_X0, _base, _off_reg);
    if _type == t_BYTE then
        ;;; LDRB Wt, [Xn]:  use unsigned offset 0
        drop_w(_LDRB_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_SHORT then
        drop_w(_LDRH_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_INT then
        drop_w(_LDRW_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_WORD or _type == t_DOUBLE then
        drop_w(_LDR_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_SGN_BYTE then
        drop_w(_LDRSB_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_SGN_SHORT then
        drop_w(_LDRSH_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_SGN_INT then
        drop_w(_LDRSW_IMM _biset _shift(_X0, _5) _biset _dst);
    elseif _type == t_SGN_WORD then
        ;;; Signed word = full 64-bit load (sign doesn't matter)
        drop_w(_LDR_IMM _biset _shift(_X0, _5) _biset _dst);
    else
        mishap(0, 'drop_field_load: unsupported type');
    endif;
enddefine;

;;; drop_field_store:
;;;     Store a field value of the given type.

define lconstant drop_field_store(_type, _src, _base, _off_reg);
    lvars _type, _src, _base, _off_reg;
    drop_add_reg(_X0, _base, _off_reg);
    if _type == t_BYTE or _type == t_SGN_BYTE then
        drop_w(_STRB_IMM _biset _shift(_X0, _5) _biset _src);
    elseif _type == t_SHORT or _type == t_SGN_SHORT then
        drop_w(_STRH_IMM _biset _shift(_X0, _5) _biset _src);
    elseif _type == t_INT or _type == t_SGN_INT then
        drop_w(_STRW_IMM _biset _shift(_X0, _5) _biset _src);
    elseif _type == t_WORD or _type == t_SGN_WORD or _type == t_DOUBLE then
        drop_w(_STR_IMM _biset _shift(_X0, _5) _biset _src);
    else
        mishap(0, 'drop_field_store: unsupported type');
    endif;
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
            drop_w(_SBFM _biset _shift(_2, _16)
                         _biset _shift(_16:3F, _10)
                         _biset _shift(_X1, _5) _biset _X1);
        else
            _int(_size fi_* _n) -> _size;
            @@V_BYTES-{_size} -> _disp;
            load_literal(_WK, _size);
            ;;; ASR X1, X1, #2  (recover integer index from 2-bit-tagged popint)
            drop_w(_SBFM _biset _shift(_2, _16)
                         _biset _shift(_16:3F, _10)
                         _biset _shift(_X1, _5) _biset _X1);
            ;;; MUL X1, X1, WK
            drop_mul(_X1, _X1, _WK);
            1 -> _n;
        endif;
        ;;; ADD X0, reg, X1 {, LSL #scale}
        lvars _scale = _int(index_scale(_n));
        if _zero(_scale) then
            drop_add_reg(_X0, _reg, _X1);
        else
            ;;; ADD X0, reg, X1, LSL #scale
            drop_w(_ADD_REG _biset _shift(_X1, _16)
                            _biset _shift(_scale, _10)
                            _biset _shift(_reg, _5) _biset _X0);
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
        ;;; Recover integer offset from 2-bit-tagged popint: ASR X1, X1, #2
        drop_w(_SBFM _biset _shift(_2, _16) _biset _shift(_16:3F, _10)
                     _biset _shift(_X1, _5) _biset _X1);
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
    drop_w(_BLR _biset _shift(_WK, _5));
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
        ;;; LSL X0, X0, #2: UBFM X0, X0, #(64-2), #(63-2) = UBFM X0, X0, #62, #61
        drop_w(_UBFM _biset _shift(_16:3E, _16) _biset _shift(_16:3D, _10)
                     _biset _shift(_X0, _5) _biset _X0);
        ;;; ORR X0, X0, #3
        load_literal(_X1, _3);
        drop_w(_ORR_REG _biset _shift(_X1, _16) _biset _shift(_X0, _5)
                        _biset _X0);
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
    ;;; of the jump offset table.
    ;;; After this point we plant 7 instrs = 28 bytes:
    ;;;   ASR, LSL (popint->byte-offset), B.HI, ADR, LDR, ADD, BR
    ;;; Then (_ncases + 1) * 8 bytes of 64-bit offset entries.
    ;;; (The old "20" undercounted: it listed 5 instrs and omitted the ADD,
    ;;; so _tabend -- the out-of-range jump target and the table position --
    ;;; was 8 bytes short, faulting on any jump-table switch.)
    _asm_code_offset _add _28 _add _int((_ncases + 1) * 8) -> _tabend;

    ;;; Convert the 2-bit popint index to a BYTE offset into the 8-byte table
    ;;; entries: i = popint asr 2, then i*8 = i lsl 3.  (drop_ldr_reg below is a
    ;;; plain [Xn+Xm] with NO scale, so reg must already be the byte offset.  The
    ;;; old code did asr #3 -- a 3-bit tag AND it left the value unscaled, so the
    ;;; jump-table dispatch was wildly wrong for any switch with enough cases to
    ;;; use a jump table.)  Neither SBFM nor UBFM touches the cmp flags from
    ;;; above, so the out-of-range test still works.
    ;;; ASR reg, reg, #2  (SBFM reg,reg,#2,#63)
    drop_w(_SBFM _biset _shift(_2, _16) _biset _shift(_16:3F, _10)
                 _biset _shift(_reg, _5) _biset _reg);
    ;;; LSL reg, reg, #3  (UBFM reg,reg,#61,#60)
    drop_w(_UBFM _biset _shift(_16:3D, _16) _biset _shift(_16:3C, _10)
                 _biset _shift(_reg, _5) _biset _reg);

    ;;; If the argument was out of range, jump to after the table
    ;;; (unsigned comparison catches both negative and too large)
    drop_br_cond(_cc_HI, _tabend);

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

    ;;; ADR X1, #16:  X1 = PC + 16
    ;;; ADR: 0 immlo(2) 10000 immhi(19) Rd
    ;;; imm = 16, immlo = 16 & 3 = 0, immhi = 16 >> 2 = 4
    drop_w(_16:10000000 _biset _shift(_4, _5) _biset _X1);

    ;;; LDR X1, [X1, reg]   (reg is already the i*8 byte offset)
    drop_ldr_reg(_X1, _X1, _reg);

    ;;; ADD X1, PB, X1  then  BR X1
    drop_add_reg(_X1, _PB, _X1);
    drop_w(_BR _biset _shift(_X1, _5));

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
        ;;; Reconstruct popint (2-bit): LSL reg, reg, #2 then ORR with 3
        ;;; (was << 3 | 7, a 3-bit tag).  LSL #2 = UBFM reg,reg,#62,#61.
        drop_w(_UBFM _biset _shift(_16:3E, _16) _biset _shift(_16:3D, _10)
                     _biset _shift(_reg, _5) _biset _reg);
        load_literal(_X1, _3);
        drop_w(_ORR_REG _biset _shift(_X1, _16) _biset _shift(_reg, _5)
                        _biset _reg);
        drop_push_reg(_reg, _USP);
    endunless;
enddefine;

;;; {I_PLOG_IFNOT_ATOM ^fail_label ^I_BRCOND}

define I_PLOG_IFNOT_ATOM();
    if asm_instr!INST_ARGS[_1] /== I_BRCOND then
        mishap(0, 'I_PLOG_IFNOT_ATOM with unexpected arguments');
    endif;
    drop_br_cond(_cc_NE, _int(fast_front(asm_instr!INST_ARGS[_0])));
enddefine;

;;; {I_PLOG_TERM_SWITCH ^fail_label I_BRCOND ^var_label I_BRCOND}

define I_PLOG_TERM_SWITCH();
    if asm_instr!INST_ARGS[_1] /== I_BRCOND or
       asm_instr!INST_ARGS[_3] /== I_BRCOND then
        mishap(0, 'I_PLOG_TERM_SWITCH with unexpected arguments');
    endif;
    drop_br_cond(_cc_HI, _int(fast_front(asm_instr!INST_ARGS[_2])));
    drop_br_cond(_cc_CC, _int(fast_front(asm_instr!INST_ARGS[_0])));
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
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_CALLQ();
    load_proc(false);
    load_literal(_WK, _popenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_CALLP();
    load_proc(true);
    ;;; Load PD_EXECUTE from the procedure record
    drop_load_off(_X1, _X0, _0);
    drop_w(_BLR _biset _shift(_X1, _5));
enddefine;

define I_CALLPQ();
    load_proc(false);
    drop_load_off(_X1, _X0, _0);
    drop_w(_BLR _biset _shift(_X1, _5));
enddefine;

define I_CALLS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_CALLPS();
    drop_pop_reg(_X0, _USP);
    drop_load_off(_X1, _X0, _0);
    drop_w(_BLR _biset _shift(_X1, _5));
enddefine;

define I_UCALL();
    load_proc(true);
    load_literal(_WK, _popuenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_UCALLQ();
    load_proc(false);
    load_literal(_WK, _popuenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_UCALLP();
    load_proc(true);
    load_literal(_WK, _popuncenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_UCALLPQ();
    load_proc(false);
    load_literal(_WK, _popuncenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_UCALLS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popuenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_UCALLPS();
    drop_pop_reg(_X0, _USP);
    load_literal(_WK, _popuncenter);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_CALLABS();
    load_literal(_X0, asm_instr!INST_ARGS[_0]);
    drop_load_off(_X1, _X0, @@PD_EXECUTE);
    drop_w(_BLR _biset _shift(_X1, _5));
enddefine;

define I_CHAIN_REG();
    lvars _reg;
    if Is_register(asm_instr!INST_ARGS[_0]) ->> _reg then
        ;;; Load PD_EXECUTE and branch to it
        drop_load_off(_WK, _int(_reg), @@PD_EXECUTE);
        drop_w(_BR _biset _shift(_WK, _5));
    else
        mishap(0, 'I_CHAIN_REG without register unimplemented');
    endif;
enddefine;

define I_CALLSUB();
    ;;; X0 may be in use for passing arguments, so use WK (x16)
    load_literal(_WK, asm_instr!INST_ARGS[_0]);
    drop_w(_BLR _biset _shift(_WK, _5));
enddefine;

define I_CHAINSUB();
    load_literal(_X0, asm_instr!INST_ARGS[_0]);
    drop_w(_BR _biset _shift(_X0, _5));
enddefine;

define I_CALLSUB_REG();
    lvars _addr, _reg;
    fast_front(asm_instr!INST_ARGS[_0]) -> _addr;
    if Is_register(_addr) ->> _reg then
        drop_w(_BLR _biset _shift(_int(_reg), _5));
    else
        ;;; absolute address
        load_literal(_WK, _addr);
        drop_w(_BLR _biset _shift(_WK, _5));
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
;;;     count the register-locals (x21..x25) recorded in _regmask.
define lconstant I_create_sf_nreg() -> _nreg;
    lvars _nreg = _0, _rnum = _21;
    while _rnum _slteq _25 do
        if _regmask _bitst _shift(_1, _rnum) then _nreg _add _1 -> _nreg endif;
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
    _21 -> _rnum;
    while _rnum _slteq _25 do
        if _regmask _bitst _shift(_1, _rnum) then
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
    _21 -> _rnum;
    while _rnum _slteq _25 do
        if _regmask _bitst _shift(_1, _rnum) then
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
    drop_w(_RET_INSTR);
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
    drop_w(_SBFM _biset _shift(_1, _16) _biset _shift(_16:3F, _10)
                 _biset _shift(_X0, _5) _biset _X0);
    load_literal(_X3, _3);
    drop_w(_ORR_REG _biset _shift(_X3, _16) _biset _shift(_X0, _5)
                    _biset _X0);
    drop_push_reg(_X0, _USP);
enddefine;

;;; {I_SETSTACKLENGTH ^saved_stacklength ^nresults}

define I_SETSTACKLENGTH();
    lvars _nresults;
    if asm_instr!INST_ARGS[_1] ->> _nresults then
        ;;; a known number of results (a popint):
        ;;; expand code for "_setstklen" inline
        lvars _reg = load_fsrc_to_reg(_0, _X2);
        ;;; Expected USP = userhi - (saved_len + nresults) items * 8 bytes.
        ;;; popints are (k<<2)+3 (2-bit tag): saved + (nresults-6) = (s+n)<<2
        ;;; = items*4, then double to items*8.  (The old #14 magic assumed a
        ;;; 3-bit tag where popint already carried the <<3 word-scale.)
        load_literal(_X3, _nresults _sub _6);
        drop_add_reg(_X2, _reg, _X3);       ;;; X2 = (saved+nresults)*4
        drop_add_reg(_X2, _X2, _X2);        ;;; X2 = (saved+nresults)*8 bytes
        load_literal(_X3, ident _userhi);
        drop_load_off(_X3, _X3, _0);
        drop_sub_reg(_X2, _X3, _X2);
        ;;; If USP == expected, skip the call; else call _setstklen_diff.
        ;;; AArch64 has no conditional BLR.  load_literal is VARIABLE length
        ;;; (2 instrs MOVZ+MOVK for a 32-bit code address), so we must load WK
        ;;; BEFORE the branch and have the B.EQ skip only the single BLR (+8).
        ;;; The previous code loaded WK *after* a B.EQ +12: on the equal path
        ;;; (USP==expected, the COMMON case) it branched straight onto the BLR
        ;;; while skipping the WK load, so `BLR WK` jumped to a stale/garbage
        ;;; address and smashed the heap -- the corruption that blocked Lisp
        ;;; eval once the _setstklen underflow was fixed.  Loading WK first and
        ;;; branching +8 (one instruction, the BLR) is robust to load_literal's
        ;;; length and leaves WK valid on the fall-through.
        load_literal(_WK, _setstklen_diff);
        drop_cmp_reg(_USP, _X2);
        drop_br_cond(_cc_EQ, _asm_code_offset _add _8);
        drop_w(_BLR _biset _shift(_WK, _5));
    else
        ;;; general case, simply call _setstklen
        load_literal(_WK, _setstklen);
        drop_w(_BLR _biset _shift(_WK, _5));
    endif;
enddefine;

;;; {I_LISP_TRUE}
;;;     replace <false> result on top of stack by nil.

define I_LISP_TRUE();
    ;;; Replace a <false> on top of the user stack with nil; leave anything
    ;;; else untouched.  No conditional STR on AArch64, so: load nil into X1
    ;;; BEFORE the branch (load_literal is variable length -- 2 instrs for the
    ;;; nil address), compare, then B.NE skips ONLY the single STR (+8).
    ;;; The old code branched +12 and loaded nil AFTER the B.NE, so on the NE
    ;;; path (top /== false, the common case) it jumped onto the STR with X1
    ;;; still holding <false> and overwrote the live top-of-stack value with
    ;;; <false> -- pervasive value corruption (I_LISP_TRUE backs every Lisp
    ;;; boolean coercion).
    load_literal(_X1, false);
    drop_load_off(_X0, _USP, _0);
    drop_cmp_reg(_X0, _X1);
    load_literal(_X1, nil);
    drop_br_cond(_cc_NE, _asm_code_offset _add _8);
    drop_store_off(_X1, _USP, _0);
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
    ;;; load_literal is VARIABLE length, so all loads come before the
    ;;; branches and every branch skips a fixed number of instructions.
    load_literal(_WK, _checkall);
    load_literal(_X1, ident _trap);
    drop_load_off(_X1, _X1, _0);
    load_literal(_X2, ident _userlim);
    drop_load_off(_X2, _X2, _0);
    drop_cmp_imm(_X1, _0);
    ;;; trap set: skip the userlim test, straight to the call
    drop_br_cond(_cc_NE, _asm_code_offset _add _12);
    drop_cmp_reg(_X2, _USP);
    ;;; _userlim <= USP means the stack is fine: skip the single BLR
    drop_br_cond(_cc_LS, _asm_code_offset _add _8);
    drop_w(_BLR _biset _shift(_WK, _5));
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
                _shift(_1, _int(Is_register(reg))) _biset _regmask -> _regmask
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
    ;;; pooled literals everywhere, so it is gated for this port.
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
    ;;; Not Darwin-specific: the invariant and the damage are the same on
    ;;; ELF, which the Pass 0b comment above says outright.
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
