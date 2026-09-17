# Porting Poplog to RISC-V (rv64gc / Linux)

Status: **COMPLETE (2026-06).** Poplog runs natively on 64-bit RISC-V. All four
languages — **Pop-11, Common Lisp, Prolog, and Standard ML** — build natively and
run on real hardware, plus a full terminal-VED `basepop11`. Validated on a
**StarFive VisionFive** (JH7100, dual SiFive U74, RV64GC, Ubuntu 24.04):
`tools/validate-riscv64.sh` = **14/14 gates PASS**. The backend lives in
`pop/src/syscomp/riscv64/{sysdefs,asmout,genproc}.p` with the hand-written runtime
in `pop/src/riscv64/*.s`. (The roadmap / phase content below is retained as the
build-up reference; everything in it is done.)

## As-built summary

* **Self-hosting on silicon, no qemu:** the full ladder builds natively on the
  StarFive — `corepop → popc → srclib → new_corepop → basepop11 → startup.psv →
  {clisp,prolog,pml}.psv`. (Codegen was developed cross-emitting riscv64 `.s`
  from an x86-64 host under qemu-user; the final build + validation are native.)
* **Languages (all RUN-verified on hardware):** Pop-11 (`maplist`, closures,
  `for…in_vector`), Common Lisp (`fact 12`, `mapcar`, `(symbolp …) → (T NIL T)`),
  Prolog (recursive `append`, factorial, compound unify, clean error reporting),
  Standard ML (`rev`, λ-application, type inference under a PTY).
* **FFI float ABI (LP64D):** `tools/ffi-float-regression.p` passes
  (`pow`/`atan2`/`hypot`/`cbrt` marshalled through `fa0–fa7`).
* **Full terminal VED:** `basepop11` links with VED (no `-noved`); the editor
  loads and renders. Needs the far-call fix (#17 below).

## Build / run (native, on the RISC-V box)

* Every invocation runs under **`setarch -R`** (ASLR off): Poplog restores its
  `.psv` images — and `basepop11` its own saved state — at FIXED virtual
  addresses, which collide with the program/stack mapping under ASLR.
* `POP__as` points at a wrapper adding `-march=rv64gc`
  (`#!/bin/sh` … `exec as -march=rv64gc "$@"`).
* After a **genproc/asmout/sysdefs** change, rebuild `popc` FIRST
  (`rm -f stamp_popc stamp_srclib stamp_new_corepop target/obj/src.{olb,wlb}`),
  then srclib, then basepop11 — a stale `popc` / `src.olb` hides codegen fixes.
  An `ass.p` / `*.s` (runtime-assembler) change is srclib-only (skip stamp_popc).
* Validate: `./tools/validate-riscv64.sh [--rebuild]`.

## Codegen / link bugs found & fixed (17)

The recurring theme (as on arm64) is `load_to_reg` returning an already-resident
register that a later load clobbers; plus several RISC-V-specific hazards from its
**flagless compares** (the branch re-reads operand *registers* at emit time) and
**relaxed branches** (the conditional form is a fixed 8-byte `b.!cc ; j`).

1–12. Earlier bugs (commits up to `313735a`) — M-op operand order, auto-index
load widths, the `gen_test` tag-test clobbers, `m_parith_test`, the runtime
assembler's `Check_br_range` / `I_SWITCH` go_on table / B-type branch relaxation,
and the `aprolog.s` term/pair switch (the Prolog blocker). See the
`project_poplog_riscv64_port` memory and the commit log for each.
13. **`_setstklen` register mismatch** (`5fd1a9a`) — the inline
`I_SETSTACKLENGTH` computed the stack-fill bound into `_X2` (=x12) but the
hand-written `_setstklen_diff` reads it from `t0` (=x5); a stale `t0` made the
nil-fill loop overwrite `ERROR`'s identifier — the Lisp `defs.lsp:40` wild store
that blocked the Lisp build for the whole port.
14–15. **`I_SETSTACKLENGTH` / `I_LISP_TRUE` skip offset `+8 → +12`** (`5fd1a9a`,
`2823ce0`) — `drop_br_cond` plants an 8-byte relaxed branch, so skipping the one
4-byte instruction after it needs +12, not arm64's +8 (single 4-byte branch).
16. **`I_LISP_TRUE` deferred-compare operand clobber** (`2823ce0`) — nil was
loaded into the compare's rhs register between the cmp and the branch; with no
flags the branch re-reads the (now-nil) register, so SYMBOLP / the "boolean"
external coercion compared `top == nil` not `top == false` and leaked pop11
`<false>` into Lisp as `#<FALSE>` (read as truthy).
17. **R_RISCV_JAL far-call** (`1e0d22d`) — a chain (tail-call) to a procedure
label emitted `j` (±1MB) and overflowed linking VED; it now emits `tail`
(auipc+jalr, ±2GB, linker-relaxed back to `j` when in range), mirroring the
`bl → call` the cross-compiler already used.

## Hardware note

The StarFive's kernel exposes **no hardware watchpoints** via ptrace (gdb falls
back to single-stepping, infeasible here). The Lisp wild store was instead caught
with a **qemu-user 8.2 TCG memory-write plugin** (built on the x86-64 host) plus
in-tree `_extern printf` instrumentation — see the memory file for the technique.

## Fixed: closure churn + auto-GC → stale-I-cache SIGILL

Found by `bench-poplog.p`'s `closures1M`; **fixed** by hardening the i-cache
flush (commit `refs #12`).

**Symptom.** Creating many short-lived closures while the GC runs SIGILLed on
real silicon. A closure is *executable heap code*, and when an address is freed
and re-used for a new closure the freshly written code was occasionally still
stale in the I-cache at call time — the bytes in memory were a valid `auipc`,
but the I-cache held something else. **Real-hardware-only**: QEMU re-translates
self-modified code, so it never showed in emulation (exactly the `fence.i` /
I-cache hazard flagged below). It never affected the four-language validation
(`validate-riscv64.sh` = 14/14) — a closure-churn stress path, not a functional
regression.

**Diagnosis.** The flush *was* invoked: `CACHEFLUSH` is called from
`consclosure`→`Flush_procedure` (procedure.p) and the post-GC flush (gcmain.p),
and a probe in `Flush_procedure` confirmed the churned closures reached it. Yet
the I-cache stayed stale, and the window was so timing-fragile that *any*
instrumentation in the flush path masked it. Signature → a d-cache→i-cache
**writeback/ordering race** on the JH7100 U74: the bare range `__clear_cache`
invalidated the I-cache before the new code stores had drained to the point of
unification, so a refetch could still see old bytes.

**Fix.** `CACHEFLUSH` now calls `rv_cacheflush` (`pop/extern/lib/c_core.c`)
instead of a bare `__clear_cache`:

```c
__asm__ volatile("fence rw, rw" ::: "memory");   /* drain code stores */
__builtin___clear_cache(ptr, ptr + nbytes);      /* kernel range flush (all harts) */
__asm__ volatile("fence.i" ::: "memory");         /* local belt-and-braces */
```

The leading `fence rw,rw` orders the code stores ahead of the invalidation; the
trailing `fence.i` is a local backstop. (`pop/src/syscomp/riscv64/sysdefs.p`,
`CACHEFLUSH`.)

**Verified.** 1M closures × 20 runs and 10M × 5 runs — 150M churned closures,
zero faults (the unhardened build crashed 5/5 at 1M). The full `closures1M`
benchmark now completes (352 ms median on the VisionFive), and the fixed
basepop11 rebuilds all four language images — including the JIT/closure-heavy
clisp, which had been hanging — in seconds. A change to the flush path needs the
**full ladder** rebuilt: `CACHEFLUSH` lives in the backend `sysdefs.p`, so
`stamp_popc` must be rebuilt before `stamp_srclib` (so the new flush is baked
into the `popc` that compiles `procedure.p`/`gcmain.p`), then `new_corepop`,
`basepop11`, and the `.psv` images.

## Fixed: large-closure stub overflowed its 12-bit load immediate (2026-09-17)

`closure_cons.p`'s large-closure path (`nfroz > 16`) loaded the Exec_closure
address base-relative, `ld t5, exec_offs(a0)`, and `exec_offs` grows with
the frozval table: past 0x800 (252 frozvals) the 12-bit immediate wraps
negative and the stub jumps through two instruction words of another
procedure.  `startup.psv` carried a 331-frozval closure, so every mkimage
image crashed on restore with a wild PC while plain `syssave` images and
`.p` files worked.  arm64 is immune (unsigned, scaled `ldr` immediate).
Now loaded PC-relative from the data word 8 bytes before the code
(`auipc t5,0 ; ld t5,-24(t5)`), 7 instructions instead of 6.  Full
write-up, with the gdb chain and the decoded record:
`docs/bugs/riscv64-mkimage-restore-broken.md`.  Regression test in
`tools/tests/test_primitives.p`.

## Open issues

None currently.

## Target

| | |
|---|---|
| ISA | **RV64GC** = RV64IMAFDC (base + mul/div, atomics, single+double FP, compressed) — the Linux baseline |
| ABI | **LP64D** — 64-bit `long`/pointer, doubles passed in FP regs |
| OS / object format | Linux, **ELF**, GNU `as` syntax |
| Hardware (as built) | **StarFive VisionFive** (JH7100, dual SiFive U74, RV64GC, 7 GiB, Ubuntu 24.04) — native; codegen iterated cross-emitting under qemu-user from an x86-64 host |
| Build | console / no-GUI (`--with_no_x`); graphics is out of scope for the port |

### RISC-V facts that matter for the backend

* **Calling convention (LP64D):** integer args `a0–a7` (`x10–x17`), FP args
  `fa0–fa7`; returns in `a0`/`a1` (`fa0`/`fa1`); `sp`=`x2`, `ra`=`x1`, `gp`=`x3`,
  `tp`=`x4`, frame ptr `s0`/`fp`=`x8`; callee-saved `s0–s11`, `fs0–fs11`. This is
  the analog of the AArch64 work in `ext_arm.c` / `aextern.s` — get it wrong and
  FFI float/struct args break (cf. the arm64 `f_reg` stride + ddecimal bugs,
  `NOTES-FOR-MAINTAINERS.md` A10).
* **Self-modifying code:** Poplog generates and runs its own machine code. After
  writing code bytes, RISC-V requires a **`fence.i`** to make them visible to the
  instruction stream (the analog of AArch64 `__clear_cache`). On Linux this is
  exposed via `__builtin___clear_cache` / the `riscv_flush_icache` syscall; on
  SMP the kernel handles cross-hart flushing.
* **Tagged pointers / data model:** 64-bit word, like arm64 — reuse the arm64
  `WORD_BITS=64`, `POPINT_BITS`, alignment constants as the starting point
  (`sysdefs.p`); RISC-V has no special pointer-bit constraints.
* **PIE / relocation:** riscv64 Linux toolchains default to PIE; the engine lays
  memory at fixed addresses and is built no-PIE / no-hardening like the other
  ports. RISC-V uses `auipc`+offset for PC-relative addressing (`%pcrel_hi`/
  `%pcrel_lo` relocations) — the codegen and any hand-written `.s` must use these
  rather than absolute addresses.
* **No condition-code register:** RISC-V branches compare two registers directly
  (`beq`/`blt`/…), unlike arm64's NZCV flags — the conditional-branch lowering in
  `genproc.p` differs structurally from arm64.

## Backend surface (what has to be written)

A syscomp backend is three files (~3000 lines, cf. arm64 = 2947):

| File | Role | Effort |
|---|---|---|
| `syscomp/riscv64/sysdefs.p` | data model, OS/ABI constants, register names | small — adapt from `arm64/sysdefs.p` |
| `syscomp/riscv64/asmout.p` | emit RISC-V GAS assembly (mnemonics, directives, relocations) | large |
| `syscomp/riscv64/genproc.p` | instruction selection + procedure/frame codegen for the Poplog VM ops; must honour the frame contract (`PORTING-ARM64-FRAME-CONTRACT.md`) | large |

Plus, outside syscomp:
* C runtime / OS layer: syscalls, signal handling (SIGSEGV-driven GC grow),
  `mmap`/`mprotect`, the `fence.i` I-cache flush, and the `corepop` link recipe.
* `configure`: recognise `riscv64` → `POP_arch=riscv64` (done in Phase 0).
* A bootstrap `corepop` seed for riscv64 (see Bootstrap).

## Phase plan (mirrors the arm64 port) — ✅ all phases complete

> Historical roadmap. Phases 0–5 are done; the backend, bootstrap, and gate
> suite all landed (see the as-built summary at the top).

0. **Env + scaffolding** *(this session)* — QEMU staging (`tools/riscv-qemu.sh`),
   `configure` arch recognition, and the `sysdefs.p` skeleton.
1. **`asmout.p`** — RISC-V assembly emission: the instruction/directive
   vocabulary popc uses, ELF sections, `%pcrel`/`%hi`/`%lo` relocations,
   procedure-length field. Validate by assembling emitted `.s` with
   `riscv64-linux-gnu-as`.
2. **`genproc.p`** — lower the Poplog VM operations to RV64GC; register
   allocation over the integer/FP files; frame layout per the frame contract;
   conditional branches via register compares.
3. **C / OS runtime** — corepop link from popc-emitted ELF + the C runtime;
   `fence.i` after codegen; signal/`mmap` glue.
4. **Bootstrap** — produce the first riscv64 `corepop`, then climb the ladder
   (`popc → src → corepop → basepop11 → images`).
5. **Validation** — the gate suite (incl. the FFI float regression,
   `tools/ffi-float-regression.p`) under QEMU.

## Bootstrap strategy

Chicken-and-egg, solved the same way as arm64: **cross-target popc** on an
existing host (x86-64 or arm64 Poplog) so it emits riscv64 `.s`, **cross-assemble
+ link** with `riscv64-linux-gnu` binutils/gcc to make the first `corepop`, then
run it under QEMU to self-host the rest. (Upstream may also publish a
`corepop_riscv64` seed, as it does for Solaris — `corepop_solaris.i386`; if so,
vendor it under `nix/seeds/` like the others.)

## Test harness (QEMU)

macOS can't run RISC-V **Linux** binaries under QEMU *user-mode* (no Linux host
kernel), so on the Mac the harness is **full-system** `qemu-system-riscv64`
booting a RISC-V Linux — see `tools/riscv-qemu.sh`, configured to approximate the
Scaleway instance (rv64gc, 4 cores, 8 GB, `virt` machine, serial console / no
GUI). On a **Linux** host (e.g. the x86-64 box) the lighter loop is
`qemu-user` + `binfmt_misc` + a `riscv64-linux-gnu` cross toolchain — cross-build
and run translated binaries directly, no VM boot. Both are valid; the Linux
`qemu-user` loop is faster for iterating on codegen, the Mac full-system loop
mirrors the real machine.

## Open questions to resolve early

* Does upstream (Hebisch) already have or want a riscv64 backend? **RESOLVED:**
  no — upstream is in preservation mode (no release plan), so write it fresh.
* Vector (`V`) and the exact `-march` of the staged hardware — start at the
  portable `rv64gc` baseline, tune later.

---

# P3: genproc transformation map (validated against real output)

This is the turnkey spec for the `genproc.p` rewrite, derived by capturing the
**actual** assembly the (scaffold) riscv64 popc emits and feeding it to
`riscv64-linux-gnu-as`. The asmout (P2) directives are already correct
(`.option arch, rv64gc`, `.quad/.byte/.word/.short`, labels, `.align 3`); only
the **instructions** (genproc) remain.

## The validation loop (use this every iteration)

On red5buntu, point `POP__as` (which popc invokes per `os_comms.p:74`) at a
wrapper that saves the `.s` and runs the real assembler:

```sh
cat > /tmp/rv-as.sh <<'EOF'
#!/bin/sh
for last in "$@"; do :; done            # popc passes (as <opts> -o ofile afile)
cp "$last" /tmp/rvcap.s 2>/dev/null      # afile (the .s) is last
shift; exec riscv64-linux-gnu-as -march=rv64gc "$@"
EOF
chmod +x /tmp/rv-as.sh
( cd pop/src && POP__as=/tmp/rv-as.sh ../../poplog popc -c -nosys -od /tmp trigc.p )
# -> /tmp/rvcap.s holds the emitted assembly; assembler errors are the to-do list.
```
Edit genproc on the Mac → `rsync` syscomp/riscv64 → `make POP_arch=riscv64
stamp_popc` → re-run the above → assembler errors shrink toward zero.

## Register mapping (roles unchanged; only the physical register differs)

Poplog's register roles map straight onto the RISC-V LP64D file. RISC-V GAS
accepts both ABI names and `xN`; the `regnumber` machinery uses `xN`, so keep
that. Note `x18` is **not** reserved on RISC-V (that was arm64's platform reg);
RISC-V's reserved set is `x0`=zero, `x1`=ra, `x2`=sp, `x3`=gp, `x4`=tp.

| Role (constant) | arm64 | RISC-V | ABI |
|---|---|---|---|
| `LR` | x30 | **x1** | ra |
| `SP` (R13) | sp | **x2** | sp |
| `USP` (R10) operand stack | x19 | **x9** | s1 (callee-saved) |
| `PB` (R11) procedure base | x20 | **x18** | s2 (callee-saved) |
| `WK_REG` (R0) work/arg0 | x0 | **x10** | a0 |
| `R1` work/arg1 | x1 | **x11** | a1 |
| `CHAIN_REG` (R2) | x2 | **x12** | a2 |
| `WK_ADDR_REG_1` (R3) | x3 | **x5** | t0 |
| `WK_ADDR_REG_2` (R12) | x12 | **x6** | t1 |
| `R4` scratch | x4 | **x7** | t2 |
| `R5` 2nd work | x5 | **x28** | t3 |
| `R9` scratch | x9 | **x29** | t4 |
| `R16` (IP0) indirect-branch scratch | x16 | **x30** | t5 |
| `pop_registers` (locals) | 21,22 | **19,20** | s3,s4 |
| `nonpop_registers` (locals) | 23,24,25 | **21,22,23** | s5,s6,s7 |

Machinery edits: `regnumber`/`reglabel` loop → iterate `0..31`, drop the `x18`
skip and the `wN` (32-bit-view) names; `sp`→2, `lr`→1 (not 31/30). `as_wreg`
→ identity (RISC-V has no separate 32-bit register names; byte/half ops use the
full register with `lb/lh/lw`/`sb/sh/sw`).

## Instruction translation (from the captured `xc_sin` procedure)

| arm64 emitted | RISC-V | note |
|---|---|---|
| `sub sp,sp,#16` | `addi sp,sp,-16` | frame alloc |
| `add sp,sp,#16` | `addi sp,sp,16` | frame free |
| `str x20,[sp,#0]` | `sd s2,0(sp)` | store: `off(reg)`, not `[reg,#off]` |
| `ldr x30,[sp,#8]` | `ld ra,8(sp)` | load |
| `ldr x1,[x20,#40]` | `ld t0,40(s2)` | field load |
| `str x1,[x19,#-8]!` (push) | `addi s1,s1,-8` ; `sd t0,0(s1)` | **no pre/post-index — split into 2** |
| `ldr x1,[x19],#8` (pop) | `ld t0,0(s1)` ; `addi s1,s1,8` | likewise |
| `mov x1,#7` | `li t0,7` | immediate |
| `mov x1,x2` | `mv t0,a2` | reg move |
| `bl xc_foo` | `call xc_foo` | sets `ra`; `call` handles far range |
| `ldr x20,xc_sin-8` | `auipc s2,%pcrel_hi(L);ld s2,%pcrel_lo(1b)(s2)` | PC-relative pointer load |
| `ret` | `ret` | same mnemonic (`jalr x0,ra,0`) |
| `cmp`/`b.cond` | `beq/bne/blt/bge ...` | **no flags reg** — compare two regs and branch |

## Structural rewrites (the genuinely different parts)

1. **No auto-index addressing.** Every Poplog user-stack push/pop (`[USP,#-8]!`
   / `[USP],#8`) becomes two instructions (`addi` + `sd`/`ld`). This touches the
   operand-formatting helpers used everywhere — do it once, centrally.
2. **No condition-codes register.** arm64's `cmp` + `b.cond` becomes a single
   RISC-V compare-and-branch (`blt`, `bgeu`, `beq`, …) on two registers; the
   M-code conditional lowering in genproc changes shape.
3. **PC-relative addressing** via `auipc`+`%pcrel_hi/_lo` (literal/label loads)
   rather than arm64's literal-pool `ldr =label` / `adrp`+`add`.
4. **Immediates** are 12-bit signed; larger values need `lui`/`li` expansion
   (the assembler's `li` pseudo handles most).
5. **`PD_LENGTH`** (`.set _L3, ((_L4 - xc_sin) >> 3) + 7`) already emits fine on
   ELF (this is the easy case the Mach-O port had to fight).

Suggested edit order within genproc: register layer (above) → the central
operand formatter (load/store `off(reg)` + the push/pop split) → mnemonics in the
`asm_emit` call sites → branch lowering → PC-relative loads → the procedure
prologue/epilogue. Gate each against the validation loop.

---

## STATUS (P3 complete, P4 in progress)

### Done
- **P1/P2/P3 — codegen backend COMPLETE.** The entire `pop/src` library
  compiles through `popc` to valid RISC-V ELF objects with **0 assembler
  errors / 0 MISHAPs** (`riscv64-linux-gnu-as -march=rv64gc`). Files:
  `syscomp/riscv64/{sysdefs,asmout,genproc}.p`. Includes the no-flags branch
  lowering, the parith overflow path (hand-computed: add `(r<a)^(b<0)`, sub
  `(a<r)^(b<0)` via slt/slti/xor), and the exfunc-closure stub
  (`auipc t1,0`+`ld t2,24(t1)`+`jr t2`, fixed 4-xword size).
- **P4 runtime `.s` (6 of 10) + the C marshaller:**
  - `amain.s` — entry point / `_MAIN`.
  - `asignals.s` — `_call_sys` / `_call_sys_se` / `__pop_errsig` (the C-call ABI
    gateway).
  - `aextern.s` — FFI trampoline (`_call_external`, `_exfunc_clos_action`,
    `_pop_external_callback`). **8-byte FP buffer stride** (not arm64's 16).
  - `alisp.s`, `amove.s` — Lisp stack + move/cmp/bitfield.
  - `pop/extern/lib/ext_arm.c` — `__riscv` branch of `copy_external_arguments`
    (8-byte FP stride + single-float **NaN-boxing**), cross-compiles clean.

### Dev loop (validated)
```
# edit on the Mac, then:
rsync -a pop/src/syscomp/riscv64/ dkords@red5buntu:.../pop/src/syscomp/riscv64/
rsync -a pop/src/riscv64/         dkords@red5buntu:.../pop/src/riscv64/
ssh red5buntu 'cd .../poplog && POPLOG=$PWD/poplog
  make POP_arch=riscv64 stamp_popc            # rebuild popc if syscomp changed
  # gate one or more .s/.p: a POP__as wrapper saves the emitted .s and runs
  #   riscv64-linux-gnu-as -march=rv64gc; assembler errors are the to-do list.
  (cd pop/src && POP__as=/tmp/save.sh "$POPLOG" popc -c -nosys -od /tmp riscv64/FOO.s)'
```
Reset a stale error log between runs — a left-over `/tmp/rverrors.log` once
produced a phantom "23k binary-garbage errors" panic; the real count was 128.

### Register remap gotcha (critical)
arm64's general scratch `x0–x12` **overlaps RISC-V reserved registers**:
`x0`=zero, `x2`=sp, `x3`=gp, `x4`=tp — and this port's `USP`=x9, `PB`=x18.
So every hand-written-asm scratch must be remapped. Convention used in the
runtime `.s`:

| arm64 | riscv64 | role |
|-------|---------|------|
| `x19` USP | `x9` (s1) | user stack pointer |
| `x20` PB  | `x18` (s2) | procedure base |
| `x0–x2` (C args) | `a0–a2` (x10–x12) | C-ABI args/return |
| `x3` scratch | `a3` (x13) | scratch |
| `x5,x6` | `t1,t2` (x6,x7) | scratch |
| `x9` scratch | `t3` (x28) | **NB x9 is USP here** |
| `x10,x11,x12` | `t4,t5,t6` (x29,x30,x31) | scratch |
| FP `d0–d7` | `fa0–fa7`, `fld`/`fsd`, **8-byte stride** | FP args |
Pop register-locals (GC-scanned) = `x19,x20` (pop) + `x21,x22,x23` (nonpop).

### Remaining P4/P5 work (the large next phase)
- `aprolog.s`, `aarith.s`, `afloat.s`, `amisc.s`, `aprocess.s` — runtime `.s`.
- `riscv64/{ass.p, array_cons.p, closure_cons.p, pdr_compose.p}` — arch `.p`.
- **`ass.p` (2189 lines) is the RUNTIME ASSEMBLER** — a second code generator
  that emits **binary instruction words** (`drop_w(_BLR _biset _shift(_WK,_5))`),
  not text. Porting it means RISC-V instruction *encoding* (R/I/S/B/U/J formats),
  not mnemonic mapping. Biggest single remaining piece; needs the P5 bootstrap
  to actually test.
- **ARCHITECTURAL ITEM — Prolog flags-return convention.** The `_prolog_*`
  primitives in `aprolog.s` return their result *in the condition flags*
  (`_prolog_unify_atom` leaves flags EQ; `fail.ret` sets carry-clear), and
  `ass.p`'s `I_PLOG_IFNOT_ATOM` / `I_PLOG_TERM_SWITCH` consume them via
  `drop_br_cond(_cc_NE/_HI/_CC, label)`. **RISC-V has no flags register**, so
  `aprolog.s` and the RISC-V `ass.p` must be **co-designed**: have the routines
  return 0/1/-1 in a register (e.g. `a0`), and have the `I_PLOG_*` handlers emit
  a register test (`beqz`/`bnez`/`bltz`) instead of `drop_br_cond`. Do these two
  together.
