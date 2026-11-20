# Porting Poplog to Windows 11 (x86-64)

> **Read [`PORTING-POPLOG.md`](PORTING-POPLOG.md) first.** This document is the
> worked instance of that recipe's **OS-layer track (Part 4)** for Windows 11 on
> x86-64. It records only what is Windows-specific. Tracking issue: #20
> (checkout fix: #18).

## Status (2026-11-20): design; spikes run and passed; no Poplog code yet

| Item | State |
|---|---|
| Tree checks out on Windows (#18) | done on branch `windows-checkout` (997deac); deliberately unmerged, see §7 |
| Target, toolchain and bootstrap route | decided below |
| Spikes S1–S3 (§9) | run on Windows 11 with Cygwin 3.6.12, gcc 14.4.0, binutils 2.47; **go**, with two design changes they forced (§3.5, §3.2) |
| Spike S4, cross-emission from the Pi 5 (§9) | run; the whole system cross-compiles to PE objects and links on Windows up to the C runtime |
| Windows code so far | `sysdefs_cygwin.p`, the `POP_TARGET_OS` override, `tools/port-windows/cross-emit.sh`. Nothing in the assembly glue, the C runtime or the per-OS tables yet, so nothing runs |

Claims in this document are marked by how they were established:
**[source]** was read in this tree; **[platform]** is a documented property of
Windows, PE/COFF or Cygwin that was not tested here; **[S1]**, **[S2]**,
**[S3]** were measured by the spike of that name (§9), reproducible with
`sh tools/port-windows/spikes/run-spikes.sh` from a Cygwin shell.

---

## 0. Which axis is this? "Same ISA, new OS"

| Track | Status for this port |
|---|---|
| **ISA backend** (register plan, `genproc.p`, `ass.p`, frame contract) | **reuse** the x86-64 backend unchanged |
| **OS / platform layer** (object format, C ABI, signals, memory map, build) | **new**; this is the whole job |

It is the same shape as the Apple Silicon port
([`PORTING-ARM64-M-SILICON-OSX.md`](PORTING-ARM64-M-SILICON-OSX.md)), with one
difference that matters: on Darwin the C calling convention stayed the same and
the memory policy changed (mandatory PIE, W^X). On Windows it is the reverse.
Windows permits a fixed-address, writable-and-executable image, but the **C
calling convention differs from System V**, so the assembly glue between Pop
and C has to be rewritten.

## 1. Constraints this plan is built around

1. **No Linux on the Windows machine.** No WSL, no Docker. Stage 1 of the
   earlier plan in #20 ("WSL2, documented") is dropped from the path. It can
   still be documented for people who have it, but nothing here depends on it.
2. **The build system stays as it is**: `configure` (sh) plus GNU make driving
   `corepop`, `pglink` and `mklibpop`. The port adds a case to them; it does
   not replace them with CMake, MSBuild or anything else.
3. **First of its kind.** There is no 64-bit Windows Poplog to copy from. The
   old 32-bit NT port left `WIN32` conditionals in 11 files of `pop/src`
   **[source]**, but they are 32-bit, decades stale, and their C side is not in
   this tree. They are reference material, not a starting point.

## 2. Decision: target `x86_64-pc-cygwin`

**The first Windows Poplog is a Cygwin program**: `corepop.exe` and
`basepop11.exe` linked by Cygwin's gcc against `cygwin1.dll`, built from a
Cygwin shell with the existing `configure` and `make`.

Why Cygwin, measured against what the source needs:

| Need | Evidence in this tree | Cygwin | Native Win32 (MinGW or MSVC) |
|---|---|---|---|
| sh, GNU make, gcc, gas, ar | `configure`, `Makefile.in`, `os_comms.p` | yes | make/sh still have to come from MSYS2 or Cygwin |
| LP64 (`long` = 64 bits) | `WORD_BITS = 64`, C runtime written for LP64 | **LP64** | LLP64, `long` = 32 bits: every `long` in `c_core.c` and friends needs auditing |
| POSIX calls from Pop | about 190 distinct C functions reached through `_extern`: `fork`, `execve`, `waitpid`, `ioctl`, `tcsetattr`, `select`, `mmap`, `dlopen`, `getpwnam`, `tgetent`… **[source]** | provided | each needs a replacement |
| Signals with `siginfo`/`ucontext` | `_pop_errsig_handler` rewrites the saved PC | async signals provided; fault recovery needs a vectored exception handler **[S1]** | everything has to be built on vectored exception handlers |
| POSIX paths, `$usepop`-style env, ptys, ncurses | whole file layer, VED, `configure` insists on (n)curses | provided | the old `WIN32` path code, revived and widened to 64 bits |
| X11 / Motif, later | `pop/x` | Cygwin/X ships `libXt` and Motif | no |

A native port is an order of magnitude more work and nothing in it is needed
to get a working system. It stays possible later (§10), and the plan keeps the
pieces separable so that it would not start from zero.

**Cygwin, not MSYS2.** MSYS2's POSIX runtime (`msys-2.0.dll`) is a fork of
Cygwin, so it would work the same way, but MSYS2 intends that runtime for its
own tools and steers application builds to MinGW, which is the native LLP64
target rejected above. Cygwin is the upstream, has the X libraries, and its
ABI is the one being targeted. MSYS2 can be re-examined after first light; the
source changes would be identical.

**x86-64 only.** Windows on ARM64 is out of scope.

## 3. What changes, and where

Sizes are from reading the files, not estimates of effort.

### 3.1 Platform definitions

New `pop/src/syscomp/x86_64/sysdefs_cygwin.p`, copied from `sysdefs.p` the way
`sysdefs_freebsd.p` was. It keeps `UNIX`, `BSD_MMAP`, `BSD_MPROTECT`,
`SHARED_LIBRARIES`, and replaces `LINUX`/`UNIX_ELF` with:

- `CYGWIN`: the OS. Selects libc constants, struct layouts and library naming.
- `WIN64_ABI`: the calling convention. Gates the assembly glue in §3.3.
- `PE_COFF`: the object format. Gates `asmout.p` and the link command.

Three symbols, not one, so that a later native port can reuse `WIN64_ABI` and
`PE_COFF` and replace only `CYGWIN`.

Selection: `make_popc.p`, `make_poplibr.p` and `make_poplink.p` pick the
sysdefs file from the **host's** `sys_os_type` (the `darwin` test at line 34 /
29 / 29) **[source]**. That is right for a native build on Cygwin, where
`sys_os_type` will contain `cygwin`, but wrong for the cross build in §5, so
those three also need an override from the environment (for example
`POP_TARGET_OS=cygwin`).

There are 53 `DEF LINUX` sites in 20 files of `pop/src` **[source]**. Each one
either applies to Cygwin too or does not; the Darwin port went through the
same list (43 `DEF DARWIN` sites in 23 files), which shows where they are.

### 3.2 Object format: small

The hand-written runtime (`pop/src/x86_64/*.s`) and `asmout.p` use only
`.align .text .data .set .quad .long .file .globl .value .space .byte`
**[source]**. None is ELF-only: there is no `.type`, `.size`, `.section`,
`@PLT` or `@GOT` to translate. x86-64 PE/COFF does not prefix C symbols with
an underscore **[platform]**, so `EXTERN_NAME` stays as it is. Known edits:

- `asm_gen_exfunc_clos_code` (asmout.p:342) pads with `.align 8` only under
  `SYSTEM_V/LINUX/FREEBSD/NETBSD`; add the new target.
- Pop procedures are data records with code inside, emitted into `.text` and
  `.data`. On PE the linked `.text` is read-only and a write into it is a
  fault; marking the input object's `.text` writable with `objcopy` does not
  survive the link **[S2]**. If the system writes to records that sit in
  `.text` (open question, §11), popc must emit them into a section of another
  name declared `"xw"`: `.section .poptext,"xw"` links as a writable,
  executable section and code in it both runs and modifies itself **[S2]**.
- `.align N` means N bytes in gas for PE, as for ELF **[S2]**.

### 3.3 Calling convention: the real backend work

Windows x64 passes the first four arguments in `rcx, rdx, r8, r9` (floats in
`xmm0`–`xmm3`, by position), requires 32 bytes of caller-allocated shadow
space, and treats `rsi`, `rdi` and `xmm6`–`xmm15` as callee-saved. Cygwin's
gcc uses this convention **[platform]**. System V uses
`rdi, rsi, rdx, rcx, r8, r9` with separate float counting and no shadow space.

Neither code generator knows the C argument registers: `genproc.p` and `ass.p`
use `rsi`/`rdi`/`rcx`/`rdx` as work registers only, and every C call from Pop
funnels through two routines **[source]**. So the convention lands in a short,
fixed list:

| Routine | File | What changes |
|---|---|---|
| `do_call_sys` (`_call_sys`, `_call_sys_se`) | `asignals.s` 165–262 | loads `rdi, rsi, rdx, rcx, r8, r9`; becomes 4 register args + shadow space + stack args from the 5th |
| `_call_external` and its store routines | `aextern.s` 104–368 | `gen_storei`/`gen_storesf` assume 6 integer + 6 float registers counted separately; becomes positional, 4 slots, with a float also copied to the matching integer register so variadic callees work; the `%al` float count goes |
| `_pop_external_callback` | `aextern.s` 410–506 | `argp` arrives in `rcx` not `rdi`; must also save and restore `rsi` and `rdi`, which Pop code clobbers and C now expects preserved |
| `pop_print` | `aextern.s` 511–528 | takes and passes arguments in System V registers |
| `main` | `amain.s` 52–93 | `argv` is in `rdx` not `rsi`; exit code goes in `ecx`; drop `linux_setper`; call `__main` if C++ constructors are ever linked in |
| `__pop_error_return`, `_do_vfork`, FPE handlers | `asignals.s`, `afloat.s` | re-read against the new convention; small |

The hand-written runtime touches `xmm7` once (`aextern.s` `single_6`) and
nothing above it, so no `xmm6`–`xmm15` save area is expected beyond that one
spot **[source]**. `asm_gen_exfunc_clos_code` uses only `r10`, which is
scratch in both conventions.

All of this goes under `#_IF DEF WIN64_ABI` beside the existing code. The
System V path is not edited, so Linux and FreeBSD cannot regress from it.

### 3.4 Memory layout: fixed and low

The x86-64 backend addresses the static image with **32-bit absolute
addresses** (`movq $label, %reg`, `movq SAVED_SP, %rax`, `ass.p`'s `_reg_ABS`)
**[source]**. On Linux that works because the binary is linked `-no-pie` and
`linux_setper` turns address randomisation off. On Windows the same
requirement is met in the PE header:

- link with `-Wl,--image-base=0x400000 -Wl,--disable-dynamicbase`. With
  Cygwin's default base the link fails with `relocation truncated to fit:
  R_X86_64_32S`; with these two options all three addressing forms the backend
  uses link and run **[S3]**;
- no personality call and no re-exec are needed. `linux_setper` becomes a
  no-op, as it already is for Darwin.

The heap: Linux grows it with `brk`, directly above the binary. Saved images
hold absolute pointers, so the heap must come back at the same address on
every run. Cygwin's own `sbrk` heap is far above 4 GB and not ours to place,
so the port reuses the Darwin approach: `_pop_brk`/`_pop_sbrk` in `c_core.c`
over one reserved region at a fixed address, with `GET_REAL_BREAK` /
`SET_REAL_BREAK` pointed at them as in `arm64/sysdefs_darwin.p` **[source]**.
None of Darwin's W^X machinery (dual mapping, fault fix-up) is needed. A
512 MB reserve made with Cygwin's `mmap(MAP_FIXED | MAP_NORESERVE)` at
`0x20000000`, read-write-execute, was granted at the requested address; code
written into it ran; and a `fork` child saw the same bytes at the same
address, with copy-on-write isolation, in 65 ms with 400 MB touched **[S3]**.
It must be `mmap`, not `VirtualAlloc`, because Cygwin's `fork` reproduces only
what it manages. Cygwin's own `sbrk` heap is at `0xa00020000` and its stack
near `0x7ffffcc50`, both far from the low region **[S3]**.
`KUSER_SHARED_DATA` sits at `0x7FFE0000` **[platform]**, so the reserve must
end below it or sit above 4 GB; whether generated code tolerates a heap above
4 GB is untested on any x86-64 target and should not be assumed.

Page size: Cygwin reports 65536, and `mmap(MAP_FIXED)` rejects an address or a
file offset that is not a multiple of 64 KB with `EINVAL` **[S3]**. Saved
images are restored with `mmap(MAP_FIXED)` (`sr_sys.p:328`) **[source]**, so
`VPAGE_OFFS = 65536` on this target. `PORTING-POPLOG.md` §4.3 already covers
that value. One trap: mapping a file with execute permission fails with
`EACCES` unless the **file itself** has its execute bit set, and adding
execute afterwards with `mprotect` fails with `EINVAL` **[S3]**. So either
saved images are written with mode 0700, or the Cygwin branch reads the
segment into the heap as the Darwin branch of `sr_sys.p` already does. The
second is safer: it does not depend on how an image file was copied around.

The call stack: Pop frames live on the C stack. Frames that drop the stack
pointer three pages at a time without touching the pages between worked up to
the limit, so no stack probing is needed in generated code **[S1]**. The limit
is the reserve in the PE header, 2 MB by default; `-Wl,--stack,0x10000000`
gave 256 MB and `getrlimit` reported it **[S1]**. Running past the limit
**ends the process with no message and exit status 0** **[S1]**, so Poplog's
own call-stack limit must stay inside the reserve, with margin.

### 3.5 Faults and signals: the top risk

Poplog depends on catching faults in Pop code: `_pop_errsig_handler` reads the
faulting PC from `uc_mcontext` and rewrites it to `__pop_errsig`, and the
float routines redirect `SIGFPE` through `__pop_fpe_handler` **[source]**.
User-stack underflow is detected this way.

**Cygwin's signals cannot do this.** A `sigaction(SA_SIGINFO)` handler is
called for a fault in table-less code and is given the right faulting address,
but its change to `uc_mcontext.rip` is ignored: the faulting instruction runs
again and the handler is called again, without end (300,000 calls in five
seconds). Calling `setcontext` on the edited context from inside the handler
kills the process silently **[S1]**.

**A vectored exception handler can.** Registered from C at start-up with
`AddVectoredExceptionHandler`, it runs before any unwinding and receives a
`CONTEXT` whose `Rip` it may rewrite, which is exactly the operation
`_pop_errsig_handler` performs. It recovered every case tried, three times
over: a bad read and an integer divide fault in static code with a non-C
stack, a bad read in code generated at run time, and a call to an unmapped
address **[S1]**. So on this target the error-signal path is a vectored
handler that fills `__pop_sigcontext` and redirects to `__pop_errsig` (or to
`__pop_fpe_handler`). It is plain Win32 and would serve a native port
unchanged.

Two things the handler must get right, neither tested yet:

- It sees every exception in the process before Cygwin does, and Cygwin uses
  access violations internally (for instance to turn a bad pointer passed to a
  system call into `EFAULT`). The handler must claim only faults that belong
  to Poplog and pass the rest on with `EXCEPTION_CONTINUE_SEARCH`. The
  existing C handler already separates "in Pop" from "outside Pop"
  **[source]**; the same test applies.
- It maps Windows exception codes to the signal numbers and `si_code` values
  the Pop side expects in `__pop_sigcontext`.

Asynchronous signals (`SIGINT`, `SIGALRM`, `SIGCHLD`) go through Cygwin's
emulation. Cygwin has no `SIGIO`-driven I/O, but `c_core.c` already carries a
`SIM_ASYNC_IO` path written for SCO (lines 1100–1186) **[source]**, which is
the natural branch to take. System V shared memory (`shmget` and friends)
needs the `cygserver` daemon on Cygwin and is left out at first.

### 3.6 Constants and struct layouts: the quiet killer

`unixdefs.ph`, `unix_tty.ph`, `unix_select.ph` and the signal tables carry
per-OS numbers and layouts in `#_IF DEF LINUX … #_ELSEIF DEF DARWIN` chains
**[source]**. Cygwin's values are its own: signal numbers, `O_*` flags,
`errno` values, `termios`, `stat`, `dirent`, `sigaction`. A wrong one does not
fail to build; it fails at run time, far from the cause.

Rule for this port: **no constant is typed in by hand.** A small C program
compiled with Cygwin's gcc prints every value and offset the `.ph` files need,
and the Cygwin branches are written from its output. Where a layout is awkward
the port uses a C shim instead, as `pop_stat.c` already does for `stat`
(see `docs/bugs/aarch64-stat-layout.md`).

### 3.7 Build system: a case, not a redesign

- `configure`: add `CYGWIN*` to the `uname -s` handling next to `Darwin`
  (`POP_arch=x86_64`, the link options from §3.4, skip the `-no-pie` and
  `--hash-style` probes that are ELF-only).
- `os_comms.p:29`: add the new target to the gcc-as-linker branch.
- `./configure --with_no_x` runs as it is under Cygwin's sh and stops where it
  should, at "corepop is missing in target tree"; GNU make is 4.4.1 **[S2]**.
  Nothing past the seed check has been exercised.
- `Makefile.in:171`: `ln -s corepop popc` and its two siblings work as
  written. With only `corepop.exe` present, `ln -s corepop popc` makes a link
  that runs, and the program sees `argv[0]` as `./popc`, which is how corepop
  tells which tool it is being **[S2]**. No copies needed.
- `.exe`: gcc writes `corepop.exe` when asked for `corepop`, and
  `mv corepop new_corepop` renames it to `new_corepop.exe` **[S2]**. Rules
  that test for a file by its bare name (`[ -f … ]` works; make prerequisites
  such as `${popsys}/corepop` may not) are found by running them once a seed
  exists.
- `external.ph`: shared libraries are `.dll`, as Darwin added `.dylib`.
- `-Wl,-export-dynamic` has no PE equivalent: a DLL cannot leave symbols to be
  resolved from the executable that loads it. This affects libraries that
  call back into Poplog (`libXpw`, some packages) and is deferred with them.

## 4. Scope for first light

**In:** `corepop.exe`, `basepop11.exe`, terminal VED, `startup.psv`, the
Lisp, Prolog and ML images, `sysobey`/pipes, `exload` of a plain DLL.

**Out, to be added back one at a time:** X and Motif, the ImGui graphics
backends, `pop_jit.c`, System V shared memory, the neural and vision
libraries, anything that needs `-export-dynamic`.

## 5. Bootstrap: where the first `corepop.exe` comes from

A seed cannot be built on the target (`PORTING-POPLOG.md` §6), and this
project's Windows machine has no Linux. The Apple Silicon port already solved
the same shape of problem: the cross seam is `poplink`, which emits assembler
text and a link script, and those are finished on the target
(`PORTING-ARM64-M-SILICON-OSX.md` §2) **[source]**.

```
GitHub Actions, ubuntu runner            GitHub Actions, windows runner (Cygwin)
  seed: nix/seeds/corepop-x86_64-linux     gcc -c  the .s files
  POP_TARGET_OS=cygwin                     gcc -c  the C runtime (real headers)
  popc + poplink with capture wrappers     link with the options from §3.4
  for POP__as / POP__cc                    run the first rungs of the ladder
        │                                          │
        └── artifact: .s, .a, poplink_cmnd ────────┴──► corepop.exe  (seed)
```

- The Linux job needs no Windows toolchain. As an early check it can assemble
  the output with `x86_64-w64-mingw32-as` (same COFF object format,
  `binutils-mingw-w64` on Ubuntu), which reports bad directives without
  waiting for the Windows job.
- The Windows job installs Cygwin with `gcc-core`, `binutils`, `make`,
  `libncurses-devel` and `gdb`.
- Once a seed runs, it is vendored as `nix/seeds/corepop-x86_64-cygwin` and
  published by the existing `corepops-release.yml`. From then on a Windows
  developer needs only Cygwin and that download; the cross job remains as the
  way to regenerate the seed.
- In practice the host so far is the project's Pi 5 (aarch64), driven by
  `tools/port-windows/cross-emit.sh`; the CI job is the same script on a
  runner and has not been set up.
- Any working Poplog can stand in for the Linux job (the Pi 5 or a Mac), since
  popc is architecture-neutral Pop. CI is preferred because it is repeatable
  and needs nobody's machine.

This also gives the port its CI from the first day, which #10 asks for
anyway.

## 6. Developer set-up on Windows 11

1. Clone with ordinary Git for Windows, naming the branch (the default branch
   does not check out on Windows, and this one stays unmerged for now):
   `git clone --branch windows-checkout https://github.com/IoTone/poplog.git`.
   `.gitattributes` keeps LF line endings.
2. Install Cygwin (`setup-x86_64.exe`) with `gcc-core`, `binutils`, `make`,
   `libncurses-devel`, `gdb`.
3. Put the seed at `target/pop/corepop.exe`.
4. From a Cygwin shell: `./configure --with_no_x && make all`.

Visual Studio, MSYS2 and WSL are not needed.

## 7. Phases

| Phase | Work | Done when |
|---|---|---|
| 0 | Checkout fix (#18), on `windows-checkout` | done; a clone of that branch works on Windows |
| 1 | Spikes S1–S3 (§9), on the Windows machine, no Poplog needed | done 2026-11-20; results in §9 |
| 2 | `sysdefs_cygwin.p`, `asmout.p`, target override, the cross job | **part done**: the Linux-flavoured system passes the PE assembler and links (§9). The Cygwin-flavoured one stops at the first per-OS tables, which is phase 3's work |
| 3 | `WIN64_ABI` glue (§3.3), C runtime branches (§3.4–3.5), constants (§3.6), link options | `corepop.exe` starts: ladder rung 1 |
| 4 | Debug up the ladder, rungs 2–6 | `tools/validate-cygwin.sh` passes; seed published |
| 5 | Native rebuild from the published seed; generation-2 self-rebuild | `make all` on Windows with no cross step |
| 6 | Deferred items from §4, in order of demand | per item |

**Branch policy.** All of this work stays on `windows-checkout`, which is not
merged to `dev` or `master` until the port has a proven path (phase 4 at the
earliest). Nothing else depends on the branch and no other platform tests it,
so shared-file changes made here have not been checked on Linux, macOS or
RISC-V until that merge is prepared.

Phase 1 is done and the answer is **go** (§9). The next thing that can stop
the port is phase 2: it is the first time real popc output meets the PE
assembler and linker.

## 8. Validation

The ladder is `PORTING-POPLOG.md` §7 unchanged. `tools/validate-cygwin.sh`
follows `tools/validate-msilicon.sh`. Windows-specific gates to add:

- deliberate user-stack underflow and a divide by zero both produce a mishap,
  not a dead process (§3.5);
- deep recursion to the call-stack limit produces `rle` and recovers (§3.4);
- a saved image made in one process loads in a fresh one (§3.4);
- `sysobey` and a piped child after the heap has grown (fork with a large
  reserve);
- a callback from C into Pop returns with `rsi` and `rdi` intact (§3.3);
- an external call with five or more arguments, mixed integer and float, and
  one to a variadic function (`printf`).

The Linux x86-64 ladder must stay green on every change to shared files.

## 9. Spikes: results (2026-11-20)

Three small C and assembler programs in `tools/port-windows/spikes/`, built
with Cygwin's gcc. None needs a Poplog seed. Run them all with
`sh tools/port-windows/spikes/run-spikes.sh` from a Cygwin shell. Environment:
Windows 11 build 26300, Cygwin 3.6.12, gcc 14.4.0, binutils 2.47.

| | Question | Result |
|---|---|---|
| **S1** | Can a fault in code with no unwind tables be caught and resumed elsewhere? | **Yes, by a vectored exception handler only.** 12 of 12 recoveries (4 fault kinds, 3 rounds). The `sigaction` route sees the fault but cannot redirect it and loops for ever; `setcontext` from the handler kills the process. See §3.5. |
| **S1** | Does the stack grow under unprobed frames? | **Yes.** 12 KB frames touching one word each ran to within 100 KB of the limit. Limit is set by `-Wl,--stack` (2 MB default, 256 MB tested). Overflow is a silent exit with status 0. See §3.4. |
| **S2** | Does the toolchain flow survive Cygwin? | **Yes as far as it can go without a seed.** `configure` reaches the seed check; `ln -s corepop popc` works and preserves `argv[0]`; `.exe` is handled by gcc and `mv`; `.align` counts bytes. Linked `.text` is read-only and cannot be made writable from the object; a separately named `"xw"` section can. See §3.2, §3.7. |
| **S3** | Fixed base below 2 GB, 32-bit absolute relocations, a fixed executable heap reserve, and `fork`, together? | **Yes.** Needs `--image-base=0x400000 --disable-dynamicbase`; the default link fails. 512 MB read-write-execute reserve at `0x20000000` survives `fork` (65 ms with 400 MB touched). Fixed mappings need 64 KB alignment of address and file offset. Executable file mappings need the execute bit on the file. See §3.4. |

What the spikes did **not** cover, and so is still expectation:

- anything involving real popc output or a real `corepop` (phase 2 onward);
- the calling-convention glue of §3.3, which is design from reading the code;
- the vectored handler living alongside Cygwin's own exception use (§3.5);
- asynchronous signals (`SIGINT`, `SIGALRM`, `SIGCHLD`) interrupting Pop code;
- `fork` cost on a machine under memory pressure, and behaviour with antivirus
  or Exploit Protection settings other than this machine's defaults.

These supersede S1–S3 in the earlier comment on #20. That S2 (count the
System V assumptions) is answered by §3.3; that S3 (what the PE assembler
rejects) is largely answered by §3.2 and is finished by the mingw assembler
check in §5.

### Later the same day: S4 and the first cross-emission

**S4, the memory break under the fault handler** (`spikes/s4_break.c`): a
1.5 GB reserve at `0x10000000` mapped `PROT_NONE` with `MAP_NORESERVE`, the
break moved by `mprotect`. Raising the break makes pages usable at once;
anything above the break faults and the vectored handler recovers it;
lowering the break makes the pages fault again and hands them back (they read
zero when the break is raised again). All from code with no unwind tables.
One requirement surfaced: **a forked child does not inherit the vectored
handler.** Without re-registering it the test hangs or dies silently; with
`pthread_atfork(NULL, NULL, install)` the child has the heap, can grow it,
and still faults above the break. This is the design for `_pop_brk` on this
target (§3.4) and a must-do for the handler (§3.5).

**Cross-emission** (`tools/port-windows/cross-emit.sh`, run on the Pi 5, an
**aarch64** host, with the aarch64 seed and Debian's
`binutils-mingw-w64-x86-64` unpacked in a home directory; about 17 minutes):

| Run | Result |
|---|---|
| `POP_TARGET_OS=linux` (unchanged sources, PE assembler) | cross popc built; all 311 assembler inputs from `pop/src` accepted by the PE assembler with **no errors**; poplink produced `poplink_1..4.o`, `poplink_dat.o` (`pe-x86-64`) and a 2.5 MB `src.olb`; no mishaps |
| Those objects linked on Windows with Cygwin gcc at the low image base, without `-lpop` | no relocation or format errors. The only undefined symbols are Poplog's own C runtime (`_pop_*`, `pop_*`, `do_bgi_*`, `__pop_*`) plus `brk` and `linux_setper`, both of which the Cygwin sysdefs removes. **Every libc function the system calls exists in Cygwin** |
| The C runtime compiled with Cygwin gcc, unchanged | 9 of 10 files compile. `c_core.c` has 3 errors: two from the old `struct sigcontext` handler (it needs the `ucontext` branch enabled for `__CYGWIN__`) and `FIOASYNC` (take the `SIM_ASYNC_IO` path, as predicted in §3.5) |
| `POP_TARGET_OS=cygwin` | the override works; 293 of 311 files compile; popc stops at three places where a per-OS chain has no Cygwin clause: `external.ph:101` (shared-library naming), `unix_tty.ph:72` (`termios`), `sysutil.p:129` (`UNIX_USRSTACK`). popc reports one error per file, so more will follow these, and chains that fall through to a generic BSD clause do not report at all (§3.6) |

So the object-format question is closed, a host of a different architecture
is fine, and the remaining work is what §3.3 to §3.6 describe: the tables,
the C runtime branch, and the calling-convention glue. The first run used the
Linux system description, so its objects are a format check only; they are
not a Windows Poplog and would not run.

## 10. Later: a native build

If a build with no `cygwin1.dll` is ever wanted, what carries over is
`WIN64_ABI` (all of §3.3), `PE_COFF`, the fixed layout, and the vectored
fault handler. What has to be written is everything Cygwin was supplying:
process creation, the file and path layer, terminal handling, async signals,
and an LLP64 audit of the C runtime. That decision is better made with a
working Cygwin system to measure against.

## 11. Open questions

- Does the system write into Pop records that live in `.text` (§3.2)? If so,
  popc needs the `.poptext` section; if not, nothing changes.
- A process that dies of stack overflow, or of a fault the handler does not
  claim, can exit silently with status 0 **[S1]**. The validation script must
  check for expected output, never for exit status alone.
- Is a heap above 4 GB safe for generated x86-64 code (§3.4)? It would lift
  the size limit that a reserve below `0x7FFE0000` implies.
- Machines with system-wide mandatory ASLR switched on in Windows Exploit
  Protection (off by default): confirm a fixed-base image still loads.
- Seed naming: `corepop-x86_64-cygwin` or `corepop-x86_64-windows`.

## Appendix: files expected to change

| Layer | Files |
|---|---|
| Platform defs | `syscomp/x86_64/sysdefs_cygwin.p` (new); `make_popc.p`, `make_poplibr.p`, `make_poplink.p` |
| Object format, link | `syscomp/x86_64/asmout.p`, `syscomp/os_comms.p` |
| ABI glue | `src/x86_64/aextern.s`, `asignals.s`, `amain.s`; review `afloat.s`, `amisc.s` |
| OS tables | `src/unixdefs.ph`, `unix_tty.ph`, `unix_select.ph`, `external.ph`, and the `DEF LINUX` sites |
| C runtime | `extern/lib/c_core.c`, `c_core.h`, `pop_timer.c`, `pop_poll.c`; new constants generator |
| Build | `configure`, `Makefile.in`, `scripts/pglink`, `scripts/poplog.in` |
| CI, tools | new cross-seed workflow, `tools/validate-cygwin.sh`, `tools/release-corepops.sh` |
| Not expected to change | `syscomp/x86_64/genproc.p`, `src/x86_64/ass.p`, the frame contract |
