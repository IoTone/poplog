/*
   Copyright Waldek Hebisch, you can distribute this file
   under terms of Free Poplog licence.
   File:        src/riscv64/closure_cons.p
   Purpose:     Construction of closures for RISC-V (rv64gc, LP64D)
   Author:      Waldek Hebisch (ARM32 original)
                AArch64 port by Poplog contributors
                RISC-V port by truedat101
*/

#_INCLUDE 'declare.ph'

constant
        procedure (Sys$-Exec_closure)
    ;


section $-Sys;

;;; Macro for dropping a 32-bit instruction word at _drop_ptr, advancing 4 bytes.
lconstant macro (
    INSTR   = [_drop_ptr!(i)++ -> _drop_ptr],
);


;;; Fill in the machine-specific part of a closure record.  _nfroz = number of
;;; frozen arguments.
;;;
;;; RISC-V differs from arm64 in two ways that change the code size:
;;;   * PB/closure-base needs auipc+addi (2 instrs), not a single adr.
;;;   * a USP push `str x,[x19,#-8]!` (1 instr) becomes `addi x9,x9,-8 ; sd`
;;;     (2 instrs), so each small-closure frozval is ld+addi+sd = 3 instrs.
;;; Large closure (nfroz>16): data word + auipc+addi + addi+sd + auipc+ld + jr
;;;   = 8 + 7*4 = 36 bytes.
;;;   The Exec_closure address is loaded PC-relative from the data word that
;;;   sits 8 bytes before the code, NOT base-relative: the base-relative
;;;   offset grows with nfroz and overflowed the ld's 12-bit signed immediate
;;;   at 0x800 (about 250 frozvals), silently wrapping negative and jumping
;;;   through two instruction words of another procedure.  This is what broke
;;;   every mkimage image on riscv64 (docs/bugs/riscv64-mkimage-restore-broken.md).
;;; Small closure: auipc+addi + nfroz*(ld+addi+sd) + ld_pdpart + ld_exec + jr
;;;   = (3*nfroz + 5) instrs.

define Cons_closure(_nfroz) -> _clos;
    lvars _drop_ptr, _nfroz, _size, _clos, _code_bytes, _code_words,
          _offs, _fv_offs, _lo12, _hi20;

    ;;; Compute code size in bytes
    if _nfroz _gr _16 then
        _36                         ;;; large: data word + 7 instructions
    else
        (_nfroz _mult _3 _add _5) _mult _4
    endif -> _code_bytes;

    ;;; Convert code bytes to words, rounding up
    ##(w)[_code_bytes | b.r] -> _code_words;

    ;;; Add header + frozval size to get total
    @@PD_CLOS_FROZVALS[_nfroz _add _code_words] _sub @@POPBASE -> _size;

    Get_store(_size) -> _clos;
    ##(w){_size} ->> _size -> _clos!PD_LENGTH;
    unless _clos!PD_LENGTH == _size then
        _clos -> Get_store();       ;;; junk it
        mishap(0, 'CLOSURE EXCEEDS MAXIMUM ALLOWABLE SIZE');
    endunless;

    ;;; Plant the code
    if _nfroz _gr _16 then
        ;;; Large closure: Exec_closure address as a data word before the code
        Exec_closure!PD_EXECUTE
            -> _clos!PD_CLOS_FROZVALS[_nfroz];

        _clos@PD_CLOS_FROZVALS[_nfroz _add _1] -> _drop_ptr;
        _drop_ptr -> _clos!PD_EXECUTE;

        ;;; auipc a0,hi ; addi a0,a0,lo  -> a0 = closure base
        _clos _sub _drop_ptr -> _offs;
        _offs _bimask _16:FFF -> _lo12;
        ;;; auipc a0,hi: 0x517 base; addi a0,a0,lo: 0x50513 base (+0x800 rounds
        ;;; for the addi sign-extension).
        _shift(_offs _add _16:800, _-12) _bimask _16:FFFFF -> _hi20;
        _shift(_hi20, _12) _biset _16:517 -> INSTR;
        _shift(_lo12, _20) _biset _16:50513 -> INSTR;

        ;;; push the closure address on USP: addi x9,x9,-8 ; sd a0,0(x9)
        _16:FF848493 -> INSTR;
        _16:00A4B023 -> INSTR;

        ;;; auipc t5,0 ; ld t5,-24(t5) ; jr t5
        ;;; The auipc is the 5th instruction (code+16); the data word is at
        ;;; code-8, i.e. 24 bytes back -- a constant, whatever nfroz is.
        _16:00000F17 -> INSTR;
        _16:FE8F3F03 -> INSTR;
        _16:000F0067 -> INSTR;
    else
        ;;; Small closure: inline frozval push + pdpart chain
        _clos@PD_CLOS_FROZVALS[_nfroz] -> _drop_ptr;
        _drop_ptr -> _clos!PD_EXECUTE;

        ;;; auipc a0,hi ; addi a0,a0,lo  -> a0 = closure base
        _clos _sub _drop_ptr -> _offs;
        _offs _bimask _16:FFF -> _lo12;
        ;;; auipc a0,hi: 0x517 base; addi a0,a0,lo: 0x50513 base (+0x800 rounds
        ;;; for the addi sign-extension).
        _shift(_offs _add _16:800, _-12) _bimask _16:FFFFF -> _hi20;
        _shift(_hi20, _12) _biset _16:517 -> INSTR;
        _shift(_lo12, _20) _biset _16:50513 -> INSTR;

        ;;; byte offset of the first frozval from the closure base
        _clos@PD_CLOS_FROZVALS[_0] _sub _clos -> _fv_offs;

        until _zero(_nfroz) do
            ;;; ld a1, fv_offs(a0) ; addi x9,x9,-8 ; sd a1,0(x9)
            _shift(_fv_offs, _20) _biset _16:00053583 -> INSTR;
            _16:FF848493 -> INSTR;
            _16:00B4B023 -> INSTR;
            _fv_offs _add _8 -> _fv_offs;
            _nfroz _sub _1 -> _nfroz;
        enduntil;

        ;;; ld a0, PD_CLOS_PDPART(a0)   (load the pdpart procedure)
        _shift(@@PD_CLOS_PDPART, _20) _biset _16:00053503 -> INSTR;

        ;;; ld t5, 0(a0)   (PD_EXECUTE == 0) ; jr t5
        _16:00053F03 -> INSTR;
        _16:000F0067 -> INSTR;
    endif;
enddefine;

endsection;     /* $-Sys */
