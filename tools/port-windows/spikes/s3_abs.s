# Spike S3 (PORTING-X86-64-WINDOWS.md section 9): the 32-bit absolute
# addressing forms the x86-64 backend emits.  They link only if the image
# sits below 2 GB.

    .data
    .globl  cell
cell:
    .quad   0x1122334455667788

    .text

# address of cell as a 32-bit immediate (genproc: movq $label, %reg)
    .globl  abs_imm
abs_imm:
    movq    $cell, %rax
    ret

# load through a 32-bit absolute address (aextern.s: movq SAVED_SP, %rax)
    .globl  abs_load
abs_load:
    movq    cell, %rax
    ret

# indirect jump to an absolute code address (asm_gen_poplink_code)
    .globl  abs_jmp
abs_jmp:
    movq    $abs_imm, %rax
    jmp     *%rax
