/*
   Copyright Waldek Hebisch, you can distribute this file
   under terms of Free Poplog licence.
   Purpose: Assembler arithmetic routines for RISC-V (rv64gc, LP64D)
   Author:  Waldek Hebisch
   AArch64 port by truedat101
   RISC-V (rv64gc/LP64D/Linux ELF) port by truedat101
*/

#_<

#_INCLUDE 'declare.ph'

lconstant macro (

    USP   = "x9",      ;;; s1 (matches genproc R10)
    LR    = "ra",      ;;; x1
    PB    = "x18",     ;;; s2 (matches genproc R11)

    _PD_EXECUTE             = @@PD_EXECUTE,
    _PD_ARRAY_TABLE         = @@PD_ARRAY_TABLE,
    _PD_ARRAY_VECTOR        = @@PD_ARRAY_VECTOR,
    _PD_ARRAY_SUBSCR_PDR    = @@PD_ARRAY_SUBSCR_PDR,

);

>_#

    .option arch, rv64gc
    .macro adr_l reg, sym
    lla \\reg, \\sym
    .endm
    .file "aarith.s"

;;; Wrapping in POP object
	.text
   .quad  Ltext_size, C_LAB(Sys$-objmod_pad_key)
Ltext_start:

;;; Register remap: arm64 scratch x0-x5/x12 -> RISC-V a0-a5/t1 (x2=sp, x3=gp,
;;; x4=tp are reserved; USP=x9, PB=x18 here).  C-ABI args land naturally in
;;; a0-a4 for the bignum do_bgi_* calls.

;;; Bit operations
DEF_C_LAB 4 (_biset)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    or   a1, a0, a1
    sd   a1, 0(USP)
    ret

DEF_C_LAB 4 (_biclear)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    not  a1, a1
    and  a1, a0, a1           ;;; bic: a0 & ~a1
    sd   a1, 0(USP)
    ret

DEF_C_LAB 4 (_bimask)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    and  a1, a0, a1
    sd   a1, 0(USP)
    ret

DEF_C_LAB 4 (_bixor)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    xor  a1, a0, a1
    sd   a1, 0(USP)
    ret

;;; Machine and POP arithmetic
DEF_C_LAB 4 (_mult)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    mul  a1, a0, a1
    sd   a1, 0(USP)
    ret

DEF_C_LAB 4 (_pmult)
    ld   a1, 0(USP)
    addi USP, USP, 8
    srai a1, a1, 2
    ld   a0, 0(USP)
    addi a0, a0, -3
    mul  a1, a0, a1
    addi a1, a1, 3
    sd   a1, 0(USP)
    ret

;;; _div: signed division with remainder.  USP[0]=divisor, USP[8]=dividend ->
;;; USP[0]=quotient, USP[8]=remainder.
DEF_C_LAB 4 (_div)
    ld   a1, 0(USP)           /* divisor */
    ld   a0, 8(USP)           /* dividend */
    div  a2, a0, a1           /* quotient */
    rem  a3, a0, a1           /* remainder */
    sd   a2, 0(USP)
    sd   a3, 8(USP)
    ret

;;; _divq: signed division, quotient only.
DEF_C_LAB 2 (_divq)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    div  a0, a0, a1
    sd   a0, 0(USP)
    ret

;;; _pdiv: pop integer division.  USP[0]=divisor, USP[8]=dividend (popints) ->
;;; USP[0]=quotient, USP[8]=remainder (popints).
DEF_C_LAB 4 (_pdiv)
    ld   a1, 0(USP)
    srai a1, a1, 2            /* mcint(divisor) */
    ld   a0, 8(USP)
    srai a0, a0, 2            /* mcint(dividend) */
    div  a2, a0, a1           /* quotient */
    rem  a3, a0, a1           /* remainder */
    slli a2, a2, 2
    ori  a2, a2, 3            /* popint(quotient) */
    sd   a2, 0(USP)
    slli a3, a3, 2
    ori  a3, a3, 3            /* popint(remainder) */
    sd   a3, 8(USP)
    ret

;;; _pmult_testovf: pop integer multiply with overflow test.
DEF_C_LAB (_pmult_testovf)
    ld   a0, 0(USP)           /* multiplier (popint) */
    ld   a1, 8(USP)           /* value (popint) */
    srai a0, a0, 2            /* mcint(multiplier) */
    addi a1, a1, -3           /* remove pop tag from value */
    mul  a2, a1, a0           /* low 64 bits */
    mulh a3, a1, a0           /* high 64 bits (signed) */
    mul  a5, a1, a0           /* clean low for the overflow compare */
    ori  a2, a2, 3            /* tag the product */
    sd   a2, 8(USP)
    srai a4, a5, 63           /* sign extension of the clean low */
    beq  a3, a4, .Lpmult_no_ovf
    ;;; Pop true/false are the ADDRESSES of C_LAB(true)/C_LAB(false) -- no deref.
    adr_l a0, C_LAB(false)
    sd   a0, 0(USP)
    ret
.Lpmult_no_ovf:
    adr_l a0, C_LAB(true)
    sd   a0, 0(USP)
    ret

;;; _pint_testovf: test if a machine integer fits in a pop integer.
DEF_C_LAB (_pint_testovf)
    ld   a0, 0(USP)
    slli a1, a0, 2
    srai a2, a1, 2
    ori  a1, a1, 3
    bne  a2, a0, .Lpint_ovf
    sd   a1, 0(USP)           /* popint -> USP[8] after the push below */
    adr_l a0, C_LAB(true)
    addi USP, USP, -8
    sd   a0, 0(USP)           /* push true on top */
    ret
.Lpint_ovf:
    adr_l a0, C_LAB(false)
    sd   a0, 0(USP)
    ret

;;; _pshift_testovf: pop integer shift with overflow test.
DEF_C_LAB (_pshift_testovf)
    ld   a0, 8(USP)           /* value (popint) */
    addi a0, a0, -3           /* remove pop tag */
    beqz a0, .Lpshift_done    /* zero value */
    ld   a1, 0(USP)           /* shift amount (machine int) */
    li   t1, 62
    bgeu a1, t1, .Lpshift_ovf
    sll  a2, a0, a1           /* shift left */
    sra  a3, a2, a1           /* shift back to check */
    bne  a0, a3, .Lpshift_ovf
    ori  a2, a2, 3            /* add pop tag */
    sd   a2, 8(USP)
.Lpshift_done:
    adr_l a0, C_LAB(true)
    sd   a0, 0(USP)
    ret
.Lpshift_ovf:
    adr_l a0, C_LAB(false)
    addi USP, USP, 8          /* pop one arg, replace the other (pre-index) */
    sd   a0, 0(USP)
    ret

;;; _posword_mul_high: high half of a 32x32 product -- NOT of a word-wide
;;; one.  This is really 32-bit code; x86_64/aarith.s carries the same note.
;;; RANSEED_BITS is the width of a C int less one (31), so the seed is at
;;; most 31 bits and random.p wants the overflow from bit 31.  mulhu takes
;;; the high half of a 64-bit product, which is 0 for every n below
;;; _SIMPLE_LIM = 2**24 -- i.e. every n the small-integer path handles.
;;; See docs/bugs/random-int-64bit.md.
DEF_C_LAB (_posword_mul_high)
    ld   a0, 8(USP)           /* first arg (seed, < 2**31) */
    ld   a2, 0(USP)           /* second arg (n, < 2**24) */
    addi USP, USP, 8
    slli a3, a0, 1            /* seed*2 -- still fits in 32 bits */
    mul  a1, a3, a2           /* both < 2**32, so the product is exact */
    srli a1, a1, 32           /* high half of the 32-bit product */
    sd   a1, 0(USP)
    ret

;;; Bignum routines.  LP64D: integer args a0-a7, return a0.

;;; _bgi_add / _bgi_sub: 5 args on USP -> do_bgi_*(a0..a4)
DEF_C_LAB (_bgi_add)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a4, 32(USP)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 40
    call EXTERN_NAME(do_bgi_add)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

DEF_C_LAB (_bgi_sub)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a4, 32(USP)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 40
    call EXTERN_NAME(do_bgi_sub)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

DEF_C_LAB (_bgi_negate)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    addi USP, USP, 24
    tail EXTERN_NAME(do_bgi_negate)

DEF_C_LAB (_bgi_negate_no_ov)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    addi USP, USP, 24
    tail EXTERN_NAME(do_bgi_negate_no_ov)

;;; left shift (4 args; pops 3, keeps a slot for the result)
DEF_C_LAB (_bgi_lshift)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 24
    call EXTERN_NAME(do_bgi_lshift)
    sd   a0, 0(USP)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

;;; logical right shift (4 args, tail call)
DEF_C_LAB (_bgi_rshiftl)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 32
    tail EXTERN_NAME(do_bgi_rshiftl)

;;; multiply (4 args, tail call)
DEF_C_LAB (_bgi_mult)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 32
    tail EXTERN_NAME(do_bgi_mult)

DEF_C_LAB (_bgi_mult_add)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 32
    tail EXTERN_NAME(do_bgi_mult_add)

DEF_C_LAB (_bgi_sub_mult)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 32
    tail EXTERN_NAME(do_bgi_sub_mult)

DEF_C_LAB (_bgi_div)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    ld   a3, 24(USP)
    addi USP, USP, 24
    call EXTERN_NAME(do_bgi_div)
    sd   a0, 0(USP)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

DEF_C_LAB (_quotient_estimate_init)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    addi USP, USP, 16
    call EXTERN_NAME(do_quotient_estimate_init)
    sd   a0, 0(USP)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

DEF_C_LAB (_quotient_estimate)
    addi sp, sp, -16
    sd   ra, 8(sp)
    ld   a0, 0(USP)
    ld   a1, 8(USP)
    ld   a2, 16(USP)
    addi USP, USP, 16
    call EXTERN_NAME(do_quotient_estimate)
    sd   a0, 0(USP)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

;;; Array indexing.  a2 = running pointer in array descriptor, t1 = total offset.
DEF_C_LAB (_array_sub)
    addi a2, PB, _PD_ARRAY_TABLE
    ld   t1, 0(a2)            /* initial offset */
    addi a2, a2, 8
    ld   a1, 0(a2)            /* dimension; check for end */
    beqz a1, .Lfin
.Larg_loop:
    ld   a3, 0(USP)
    addi USP, USP, 8
    andi t3, a3, 2
    beqz t3, .Lsub_error
    ld   a0, 8(a2)
    sub  a3, a3, a0
    bgeu a3, a1, .Lsub_error
    ld   a0, 16(a2)
    beqz a0, .Lmul
    mul  a3, a0, a3
.Lmul:
    addi a2, a2, 24          /* next dimension (3 words) */
    ld   a1, 0(a2)
    add  t1, t1, a3
    bnez a1, .Larg_loop
.Lfin:
    addi USP, USP, -8
    sd   t1, 0(USP)
    ld   a0, _PD_ARRAY_VECTOR(PB)
    addi USP, USP, -8
    sd   a0, 0(USP)
    ld   a0, _PD_ARRAY_SUBSCR_PDR(PB)
    ld   t3, _PD_EXECUTE(a0)
    jr   t3
.Lsub_error:
    addi USP, USP, -8
    tail XC_LAB(weakref Sys$-Array$-Sub_error)
    call XC_LAB(setpop)

;;; Shifts

;;; _rshift: pop integer right shift (negative count = left shift).
DEF_C_LAB (_rshift)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    srai a1, a1, 2            /* mcint(shift count) */
    srai a0, a0, 2            /* mcint(value) */
    bltz a1, .Lrshift_left
    sra  a0, a0, a1           /* positive: shift right */
    j    .Lrshift_done
.Lrshift_left:
    neg  a1, a1
    sll  a0, a0, a1           /* negative: shift left */
.Lrshift_done:
    slli a0, a0, 2
    ori  a0, a0, 3           /* popint(result) */
    sd   a0, 0(USP)
    ret

;;; _shift: pop integer left shift (kept dead, as in the arm64 source -- the
;;; DEF_C_LAB is commented there; the body assembles as unreachable code).
;;; DEF_C_LAB (_shift)
    ld   a1, 0(USP)
    addi USP, USP, 8
    ld   a0, 0(USP)
    srai a1, a1, 2
    srai a0, a0, 2
    bltz a1, .Lshift_right
    sll  a0, a0, a1           /* positive: shift left */
    j    .Lshift_done
.Lshift_right:
    neg  a1, a1
    sra  a0, a0, a1           /* negative: shift right */
.Lshift_done:
    slli a0, a0, 2
    ori  a0, a0, 3
    sd   a0, 0(USP)
    ret

    .align  3

;;; End wrapper: set size
	.text
Ltext_end:
    .set Ltext_size, Ltext_end-Ltext_start
