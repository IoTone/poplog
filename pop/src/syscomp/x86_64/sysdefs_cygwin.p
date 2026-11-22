/* --- Copyright University of Sussex 2005. All rights reserved. ----------
 > File:        src/syscomp/x86_64/sysdefs_cygwin.p
 > Purpose:     Definitions for machine & operating system
 >              (x86-64 Windows, Cygwin runtime, PE/COFF)
 > Author:      Derived from sysdefs.p (Linux ELF), 2026
 > Documentation: PORTING-X86-64-WINDOWS.md
 */

;;; Three symbols describe this target, kept apart so that a later native
;;; Windows port can reuse two of them:
;;;     CYGWIN      the operating-system layer (libc constants, struct
;;;                 layouts, library naming)
;;;     WIN64_ABI   the C calling convention (rcx, rdx, r8, r9, 32 bytes of
;;;                 shadow space; rsi and rdi callee-saved)
;;;     PE_COFF     the object format


section;

global constant macro (

    POPC_SYSDEFS_LOADED = true,


;;; === SYSTEM NAME (PC) ==============================================


    MACHINE = [[pc]],

    PC = true,
    X86_CYGWIN = true,


;;; === PROCESSOR (INTEL 80x86) =======================================


    PROCESSOR = [[80386]],      ;;; or similar

    ;;; Values for machine and C data types are defined in mcdata.p,
    ;;; and can be overidden here if necessary

    WORD_BITS       = 64,

    POPINT_BITS     = 61,

    SHORT_ALIGN_BITS = 8,       ;;; alignment in bits for short access
    INT_ALIGN_BITS   = 8,       ;;; alignment in bits for int access
    DOUBLE_ALIGN_BITS = 8,      ;;; alignment in bits for double access

    STRUCT_SHORT_ALIGN_BITS = 16,   ;;; bit alignment for short
    STRUCT_INT_ALIGN_BITS   = 32,   ;;; bit alignment for int
    STRUCT_DOUBLE_ALIGN_BITS = 64,  ;;; bit alignment for double

    ;;; Stack alignment in bits
    STACK_ALIGN_BITS = 128,

    CODE_POINTER_TYPE = "byte", ;;; type of pointer to machine code
    BIT_POINTER_TYPE = "byte",  ;;; type of pointer for bitfield access

    ;;; FRAME_LEN_32BIT = true,


;;; === OPERATING SYSTEM (UNIX BSD) ==================================


    UNIX = true,
    BERKELEY = 4.3,
    CYGWIN = 3.6,               ;;; Cygwin DLL version first targeted
    PE_COFF = true,             ;;; object format (the counterpart to UNIX_ELF)
    WIN64_ABI = true,           ;;; Microsoft x64 calling convention
    POSIX1 = 198808,            ;;; probably later than this ...
    OPERATING_SYSTEM = [[unix cygwin ^CYGWIN pe posix {^POSIX1}]],

    SHARED_LIBRARIES = true,

    BSD_MMAP        = true,      ;;; has -mmap- and -mprotect- facilities
    BSD_MPROTECT    = true,

    ;;; Windows maps memory only at multiples of its 64 KB allocation
    ;;; granularity; Cygwin reports that as the page size, and mmap MAP_FIXED
    ;;; rejects any other address or file offset (measured: spike S3).
    VPAGE_OFFS = 65536,     ;;; word address offset of a virtual page

    ;;; LOWEST_ADDRESS:
    LOWEST_ADDRESS = 0,

    ;;; Procedures to get and set the memory break and return the REAL end of
    ;;; memory.  Cygwin's own sbrk heap lies above 4 GB and is not ours to
    ;;; place, while saved images need the heap at the same address in every
    ;;; run.  So the break is emulated over a fixed reserve by
    ;;; _pop_brk/_pop_sbrk in c_core.c, as on Darwin.

    GET_REAL_BREAK =
        [procedure(); _extern _pop_sbrk(_0)@(b.r->vpage) endprocedure],

    SET_REAL_BREAK =
        [procedure(_break) -> _break;
            lvars _break = _break@(w.r->vpage);
            if _extern _pop_brk(_break@(w->b)) == _-1 then
                _-1 -> _break
            endif
        endprocedure],


;;; === OTHER =========================================================

    ;;; ANSI C returns floats as single, not double
    ANSI_C = true,
    ;;; AMD64 returns a float as 32-bits in XMM0
    C_FLOAT_RESULT_SINGLE = true,

    ;;; list of procedures to be optimised as subroutine calls
    ;;; format of entries is
    ;;;     [<pdr name> <nargs> <nresults> <subroutine name>]

    SUBROUTINE_OPTIMISE_LIST =
        [[
            [prolog_newvar  0 1 _prolog_newvar]
            [datakey        1 1 _datakey]
            [prolog_deref   1 1 _prolog_deref]
            [conspair       2 1 _conspair]
        ]],

    ;;; Old-style I_PUSH/POP_FIELD(_ADDR) instructions in ass.p
    OLD_FIELD_INSTRUCTIONS = true,

    ;;; Include M-code listing in assembly language files

    M_DEBUG = true,

    ;;; Result of external call may need sign extension

    SIGN_EXTEND_EXTERN = true,

);

endsection;     /* $- */
