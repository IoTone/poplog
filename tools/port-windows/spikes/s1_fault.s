# Spike S1 (PORTING-X86-64-WINDOWS.md section 9): routines that fault the
# way Pop code would -- no unwind tables, a stack that is not a C frame.
# Windows x64 calling convention: first argument in %rcx, second in %rdx.

    .data
    .globl  saved_sp
saved_sp:
    .quad   0

    .text

# long fault_static(long *bad): read through a bad pointer
    .globl  fault_static
fault_static:
    pushq   %rbx
    pushq   %rbp
    movq    %rsp, saved_sp(%rip)
    subq    $40, %rsp
    movq    $3, (%rsp)
    pushq   $0x1234567          # top of stack is not a return address
    movq    (%rcx), %rax        # faults
    movq    $1, %rax
    jmp     out

# long div_static(long divisor): integer divide fault when divisor is 0
    .globl  div_static
div_static:
    pushq   %rbx
    pushq   %rbp
    movq    %rsp, saved_sp(%rip)
    subq    $40, %rsp
    pushq   $0x1234567
    movq    $100, %rax
    cqto
    idivq   %rcx                # faults
    jmp     out

# long call_jit(void *fn, long arg): call fn(arg) from a non-C frame
    .globl  call_jit
call_jit:
    pushq   %rbx
    pushq   %rbp
    movq    %rsp, saved_sp(%rip)
    subq    $32, %rsp
    pushq   $0x1234567
    pushq   $0x7654321
    movq    %rcx, %rax
    movq    %rdx, %rcx
    call    *%rax
    jmp     out

# Handlers redirect the faulting thread here.
    .globl  recover
recover:
    movq    $77, %rax
out:
    movq    saved_sp(%rip), %rsp
    popq    %rbp
    popq    %rbx
    ret

# long deep(long n): recurse n times; each frame drops the stack pointer by
# three pages and touches only the lowest word, as unprobed code would.
    .globl  deep
deep:
    subq    $0x3008, %rsp
    movq    %rcx, (%rsp)
    testq   %rcx, %rcx
    jz      1f
    decq    %rcx
    call    deep
1:  addq    $0x3008, %rsp
    ret
