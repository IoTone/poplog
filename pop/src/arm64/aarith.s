/*
   Copyright Waldek Hebisch, you can distribute this file
   under terms of Free Poplog licence.
   Purpose: Assembler arithmetic routines for AArch64
   Author:  Waldek Hebisch
   AArch64 port
*/

#_<

#_INCLUDE 'declare.ph'

lconstant macro (

    USP   = "x19",
    LR    = "lr",
    PB    = "x20",

    _PD_EXECUTE             = @@PD_EXECUTE,
    _PD_ARRAY_TABLE         = @@PD_ARRAY_TABLE,
    _PD_ARRAY_VECTOR        = @@PD_ARRAY_VECTOR,
    _PD_ARRAY_SUBSCR_PDR    = @@PD_ARRAY_SUBSCR_PDR,

);

>_#

#_IF DEF UNIX_MACHO
    ;;; Mach-O PC-relative address load (backslashes doubled: popc escapes .s).
    .macro adr_l reg, sym
    adrp \\reg, \\sym@PAGE
    add  \\reg, \\reg, \\sym@PAGEOFF
    .endm
    ;;; Mach-O: a conditional branch may NOT target an external symbol; invert
    ;;; the test and reach it with an unconditional b (which may be external).
    .macro beq_x t
    b.ne 8f
    b \\t
8:
    .endm
    .macro bne_x t
    b.eq 8f
    b \\t
8:
    .endm
#_ELSE
    .arch armv8-a
    .macro adr_l reg, sym
    adrp \\reg, \\sym
    add  \\reg, \\reg, :lo12:\\sym
    .endm
    .macro beq_x t
    b.eq \\t
    .endm
    .macro bne_x t
    b.ne \\t
    .endm
#_ENDIF
    .file "aarith.s"

;;; Wrapping in POP object
#_IF DEF UNIX_MACHO
	.section	__POPSEED,__popseed
	.p2align	3
#_ELSE
	.text
#_ENDIF
   .xword  Ltext_size, C_LAB(Sys$-objmod_pad_key)
Ltext_start:

;;; Bit operations
DEF_C_LAB 4 (_biset)
    ldr x1, [USP], #8
    ldr x0, [USP]
    orr x1, x0, x1
    str x1, [USP]
    ret

DEF_C_LAB 4 (_biclear)
    ldr x1, [USP], #8
    ldr x0, [USP]
    bic x1, x0, x1
    str x1, [USP]
    ret

DEF_C_LAB 4 (_bimask)
    ldr x1, [USP], #8
    ldr x0, [USP]
    and x1, x0, x1
    str x1, [USP]
    ret

DEF_C_LAB 4 (_bixor)
    ldr x1, [USP], #8
    ldr x0, [USP]
    eor x1, x0, x1
    str x1, [USP]
    ret

;;; Machine and POP arithmetic
DEF_C_LAB 4 (_mult)
    ldr x1, [USP], #8
    ldr x0, [USP]
    mul x1, x0, x1
    str x1, [USP]
    ret

DEF_C_LAB 4 (_pmult)
    ldr x1, [USP], #8
    asr x1, x1, #2
    ldr x0, [USP]
    sub x0, x0, #3
    mul x1, x0, x1
    add x1, x1, #3
    str x1, [USP]
    ret

;;; _div: signed division with remainder
;;; USP[0] = divisor, USP[8] = dividend
;;; Result: USP[0] = quotient, USP[8] = remainder
DEF_C_LAB 4 (_div)
    ldr x1, [USP]          /* divisor */
    ldr x0, [USP, #8]      /* dividend */
    sdiv x2, x0, x1        /* quotient = dividend / divisor */
    msub x3, x2, x1, x0    /* remainder = dividend - quotient * divisor */
    str x2, [USP]           /* store quotient */
    str x3, [USP, #8]       /* store remainder */
    ret

;;; _divq: signed division, quotient only
;;; Pops divisor, replaces dividend with quotient
DEF_C_LAB 2 (_divq)
    ldr x1, [USP], #8      /* pop divisor */
    ldr x0, [USP]           /* dividend */
    sdiv x0, x0, x1         /* quotient */
    str x0, [USP]
    ret

;;; _pdiv: pop integer division
;;; USP[0] = divisor (popint), USP[8] = dividend (popint)
;;; Result: USP[0] = quotient (popint), USP[8] = remainder (popint)
DEF_C_LAB 4 (_pdiv)
    ldr x1, [USP]           /* divisor (popint) */
    asr x1, x1, #2          /* mcint(divisor) */
    ldr x0, [USP, #8]       /* dividend (popint) */
    asr x0, x0, #2          /* mcint(dividend) */
    sdiv x2, x0, x1         /* quotient */
    msub x3, x2, x1, x0     /* remainder = dividend - quotient * divisor */
    lsl x2, x2, #2
    orr x2, x2, #3          /* popint(quotient) */
    str x2, [USP]
    lsl x3, x3, #2
    orr x3, x3, #3          /* popint(remainder) */
    str x3, [USP, #8]
    ret

;;; _pmult_testovf: pop integer multiply with overflow test
;;; USP[0] = shift/multiplier (popint), USP[8] = value (popint)
;;; Result: USP[8] = product (popint), USP[0] = true/false
DEF_C_LAB (_pmult_testovf)
    ldr x0, [USP]           /* multiplier (popint) */
    ldr x1, [USP, #8]       /* value (popint) */
    asr x0, x0, #2          /* mcint(multiplier) */
    sub x1, x1, #3          /* remove pop tag from value */
    mul x2, x1, x0          /* low 64 bits of product */
    smulh x3, x1, x0        /* high 64 bits of product */
    /* Check for overflow: high must be sign extension of low */
    cmp x2, #0
    orr x2, x2, #3          /* add pop tag to product */
    str x2, [USP, #8]
    /* If x2 (before orr) was negative, x3 should be -1; if positive, x3 should be 0 */
    asr x4, x2, #63         /* sign extend: 0 or -1 */
    /* But we ORed #3 into x2, so use the original mul result.
       Recompute: check if smulh == asr(mul_result, 63) */
    mul x5, x1, x0          /* redo mul for clean comparison */
    asr x4, x5, #63
    cmp x3, x4
    b.eq .Lpmult_no_ovf
    ;;; Pop true/false are the ADDRESSES of C_LAB(true)/C_LAB(false); load the
    ;;; address (adrp+add), do not deref (the cell holds the C int 0/1).
    adr_l x0, C_LAB(false)
    str x0, [USP]
    ret
.Lpmult_no_ovf:
    adr_l x0, C_LAB(true)
    str x0, [USP]
    ret

;;; _pint_testovf: test if machine integer fits in a pop integer
;;; USP[0] = machine integer
;;; If fits: push popint below, USP[0] = true
;;; If not: USP[0] = false
DEF_C_LAB (_pint_testovf)
    ldr x0, [USP]
    lsl x1, x0, #2          /* shift left by tag bits */
    asr x2, x1, #2          /* shift back */
    orr x1, x1, #3          /* add pop tag */
    cmp x2, x0              /* did we lose bits? */
    b.ne .Lpint_ovf
    str x1, [USP]           /* popint replaces the arg in its slot (-> USP[8]) */
    adr_l x0, C_LAB(true)
    str x0, [USP, #-8]!     /* push true on top: USP[0]=true, USP[8]=popint.
                               (The old order pushed the popint then overwrote
                               it with true at USP[0], losing the popint and
                               leaving the raw machine int below.) */
    ret
.Lpint_ovf:
    adr_l x0, C_LAB(false)
    str x0, [USP]
    ret

;;; _pshift_testovf: pop integer shift with overflow test
;;; USP[0] = shift amount (machine int), USP[8] = value (popint)
;;; Result: USP[8] = shifted value or unchanged, USP[0] = true/false
DEF_C_LAB (_pshift_testovf)
    ldr x0, [USP, #8]       /* value (popint) */
    subs x0, x0, #3          /* remove pop tag */
    b.eq .Lpshift_done       /* zero value, nothing to shift */
    ldr x1, [USP]            /* shift amount (machine int) */
    cmp x1, #62              /* max useful shift for 64-bit */
    b.hs .Lpshift_ovf
    lsl x2, x0, x1           /* shift left */
    asr x3, x2, x1           /* shift back to check */
    cmp x0, x3
    b.ne .Lpshift_ovf
    orr x2, x2, #3           /* add pop tag */
    str x2, [USP, #8]
.Lpshift_done:
    adr_l x0, C_LAB(true)
    str x0, [USP]
    ret
.Lpshift_ovf:
    adr_l x0, C_LAB(false)
    ;;; pop one arg and replace the other
    str x0, [USP, #8]!
    ret

;;; Helper for random number generator.
;;; This is really 32-bit code -- see x86_64/aarith.s, which says the same.
;;; The contract is NOT "high word of a word-wide product": RANSEED_BITS is
;;; the width of a C int less one (31), so Random_genseed hands us at most a
;;; 31-bit seed and random.p wants the overflow from bit 31, i.e. the high
;;; half of a 32x32 product.  Taking the high half of a 64-bit product here
;;; (umulh) returns 0 for every n below _SIMPLE_LIM = 2**24, which is every
;;; n the small-integer path handles -- so random0(n) was always 0 and
;;; random(n) always n.  See docs/bugs/random-int-64bit.md.
DEF_C_LAB (_posword_mul_high)
    ldr x0, [USP, #8]       /* first arg (seed, < 2**31) */
    ldr x2, [USP], #8       /* second arg (n, < 2**24), pop */
    lsl x3, x0, #1          /* seed*2 -- still fits in 32 bits */
    umull x1, w3, w2        /* 32x32 -> 64 unsigned, the full product */
    lsr x1, x1, #32         /* high half of the 32-bit product */
    str x1, [USP]
    ret

;;; Bignum routines
;;; AArch64 AAPCS64: arguments in x0-x7, return in x0

;;; _bgi_add: 5 args on USP
;;; Args (top to bottom): arg0, arg1, arg2, arg3, arg4
;;; Call do_bgi_add(arg0, arg1, arg2, arg3, arg4)
DEF_C_LAB (_bgi_add)
    ;;; Save link register (16-byte aligned)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ;;; Load 5th argument and pass on control stack
    ldr x4, [USP, #32]
    ;;; Load arguments to registers per AAPCS64
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #40        /* pop 5 args */
    bl EXTERN_NAME(do_bgi_add)
    ;;; Clean control stack and return
    ldp x29, x30, [sp], #16
    ret

DEF_C_LAB (_bgi_sub)
    ;;; Save link register (16-byte aligned)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ;;; Load 5th argument
    ldr x4, [USP, #32]
    ;;; Load arguments to registers per AAPCS64
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #40        /* pop 5 args */
    bl EXTERN_NAME(do_bgi_sub)
    ;;; Clean control stack and return
    ldp x29, x30, [sp], #16
    ret

DEF_C_LAB (_bgi_negate)
    ;;; Load arguments to registers (3 args)
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    add USP, USP, #24        /* pop 3 args */
    ;;; transfer control to C code (tail call)
    b EXTERN_NAME(do_bgi_negate)

DEF_C_LAB (_bgi_negate_no_ov)
    ;;; Load arguments to registers (3 args)
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    add USP, USP, #24        /* pop 3 args */
    ;;; transfer control to C code (tail call)
    b EXTERN_NAME(do_bgi_negate_no_ov)

;;; left shift
;;; Arguments (4 on USP, top to bottom):
;;;   arg0 = destination (top of USP)
;;;   arg1 = shift amount
;;;   arg2 = length of bigint argument
;;;   arg3 = bigint argument
DEF_C_LAB (_bgi_lshift)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ;;; Load arguments to registers
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #24        /* pop 3, keep 1 slot for result */
    bl EXTERN_NAME(do_bgi_lshift)
    str x0, [USP]
    ldp x29, x30, [sp], #16
    ret

;;; logical right shift (4 args, tail call)
DEF_C_LAB (_bgi_rshiftl)
    ;;; Load arguments to registers
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #32        /* pop all 4 args */
    b EXTERN_NAME(do_bgi_rshiftl)

;;; Multiply unsigned bigint by unsigned machine integer (slice)
;;; Arguments (4 on USP, top to bottom):
;;;   arg0 = destination (top of USP)
;;;   arg1 = length of bigint argument
;;;   arg2 = bigint argument
;;;   arg3 = machine integer
DEF_C_LAB (_bgi_mult)
    ;;; Load arguments to registers
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #32        /* pop all 4 args */
    ;;; transfer control to C code (tail call)
    b EXTERN_NAME(do_bgi_mult)

DEF_C_LAB (_bgi_mult_add)
    ;;; Load arguments to registers
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #32        /* pop all 4 args */
    ;;; transfer control to C code (tail call)
    b EXTERN_NAME(do_bgi_mult_add)

;;; Subtract product from destination (4 args, tail call)
DEF_C_LAB (_bgi_sub_mult)
    ;;; Load arguments to registers
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #32        /* pop all 4 args */
    ;;; transfer control to C code (tail call)
    b EXTERN_NAME(do_bgi_sub_mult)

DEF_C_LAB (_bgi_div)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ;;; Load arguments to registers (4 args)
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    ldr x3, [USP, #24]
    add USP, USP, #24        /* pop 3, keep 1 slot for result */
    ;;; call C code
    bl EXTERN_NAME(do_bgi_div)
    str x0, [USP]
    ldp x29, x30, [sp], #16
    ret

DEF_C_LAB (_quotient_estimate_init)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    add USP, USP, #16        /* pop 2, keep 1 slot for result */
    ;;; call C code
    bl EXTERN_NAME(do_quotient_estimate_init)
    str x0, [USP]
    ldp x29, x30, [sp], #16
    ret

DEF_C_LAB (_quotient_estimate)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr x0, [USP]
    ldr x1, [USP, #8]
    ldr x2, [USP, #16]
    add USP, USP, #16        /* pop 2, keep 1 slot for result */
    ;;; call C code
    bl EXTERN_NAME(do_quotient_estimate)
    str x0, [USP]
    ldp x29, x30, [sp], #16
    ret

;;; Array indexing
    ;;; Register usage
    ;;; x2   - running pointer in array descriptor
    ;;; x12  - running total offset
DEF_C_LAB (_array_sub)
    ;;; initialize pointer to array descriptor
    add x2, PB, #_PD_ARRAY_TABLE
    ;;; get initial offset
    ldr x12, [x2], #8
    ;;; load dimension, check if end
    ldr x1, [x2]
    cbz x1, .Lfin
.Larg_loop:
    ldr x3, [USP], #8
    tst x3, #2
    b.eq .Lsub_error
    ldr x0, [x2, #8]
    sub x3, x3, x0
    cmp x3, x1
    b.hs .Lsub_error
    ldr x0, [x2, #16]
    cbz x0, .Lmul
    mul x3, x0, x3
.Lmul:
    ;;; load next dimension (advance pointer by 3 words = 24 bytes)
    add x2, x2, #24
    ldr x1, [x2]
    ;;; update total
    add x12, x12, x3
    ;;; check if end
    cbnz x1, .Larg_loop
.Lfin:
    str x12, [USP, #-8]!
    ldr x0, [PB, #_PD_ARRAY_VECTOR]
    str x0, [USP, #-8]!
    ldr x0, [PB, #_PD_ARRAY_SUBSCR_PDR]
    ldr x9, [x0, #_PD_EXECUTE]
    br x9
.Lsub_error:
    sub USP, USP, #8
    b XC_LAB(weakref Sys$-Array$-Sub_error)
    bl XC_LAB(setpop)

;;; Shifts

;;; _rshift: pop integer right shift (negative count = left shift)
;;; USP[0] = shift count (popint), USP[8] = value (popint)
DEF_C_LAB (_rshift)
    ldr x1, [USP], #8
    ldr x0, [USP]
    asr x1, x1, #2          /* mcint(shift count) */
    asr x0, x0, #2          /* mcint(value) */
    cmp x1, #0
    b.lt .Lrshift_left
    ;;; positive shift count: shift right
    asr x0, x0, x1
    b .Lrshift_done
.Lrshift_left:
    ;;; negative shift count: shift left
    neg x1, x1
    lsl x0, x0, x1
.Lrshift_done:
    lsl x0, x0, #2
    orr x0, x0, #3          /* popint(result) */
    str x0, [USP]
    ret

;;; _shift: pop integer left shift (negative count = right shift)
;;; USP[0] = shift count (popint), USP[8] = value (popint)
;;; DEF_C_LAB (_shift)
    ldr x1, [USP], #8
    ldr x0, [USP]
    asr x1, x1, #2          /* mcint(shift count) */
    asr x0, x0, #2          /* mcint(value) */
    cmp x1, #0
    b.lt .Lshift_right
    ;;; positive shift count: shift left
    lsl x0, x0, x1
    b .Lshift_done
.Lshift_right:
    ;;; negative shift count: shift right
    neg x1, x1
    asr x0, x0, x1
.Lshift_done:
    lsl x0, x0, #2
    orr x0, x0, #3          /* popint(result) */
    str x0, [USP]
    ret

    .align  3

;;; End wrapper: set size
#_IF DEF UNIX_MACHO
	.section	__POPSEED,__popseed
	.p2align	3
#_ELSE
	.text
#_ENDIF
Ltext_end:
    .set Ltext_size, Ltext_end-Ltext_start
