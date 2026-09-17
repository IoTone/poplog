# Notes for Poplog maintainers, current and future

This document records, with rationale and reproducers, the engine bugs
found and fixed on this branch (`12-mac-os-x-m-silicon-port`), plus the
performance work.  It is written for whoever maintains a Poplog tree --
upstream (https://github.com/hebisch/poplog), this fork, or a future
one.  **It is documentation, not a pull request**: every fix stands
alone, each comes with the evidence that found it, and nothing here
depends on accepting the macOS port itself.

We owe the upstream maintainer thanks: the PORTING.txt he provided was
the only living porting documentation available (everything else was
expired links and the Internet Archive), and this work would not have
started without it.

This fork's direction is platform expansion (Apple Silicon, AArch64
boards, Nix-based distribution) and feature modernisation; we maintain
these fixes here regardless of upstream interest.

---

## A. Generic engine bugs (platform-independent or all-arm64)

These are latent or live in any arm64 build, and two are fully
platform-independent.  Each was found by symptom on one platform and
then **verified present on validated arm64 Linux** before fixing.

### A1. arm64 genproc: dlocal save slots inverted vs the GC scan window
`pop/src/syscomp/arm64/genproc.p` -- THE most consequential fix.

* **Contract:** non-SPARC `m_trans.p` builds `all_dlocals` as
  `pop_dlocals <> nonpop_dlocals` ("pop ones come first"), and both
  `PD_GC_OFFSET_LEN`/`PD_GC_SCAN_LEN` and the runtime
  `Dlocal_frame_offset` (procedure.p; table index k -> frame slot
  `Ndlocals-1-k`) assume list order maps to **descending** slots, so
  pop dlocals sit at the top of the dlocal region adjacent to the pop
  register saves, where `App_calls`' GC window scans.
* **Bug:** `M_CREATE_SF` assigned slots **ascending** (its comment
  assumed "non-pop first" -- the SPARC branch's ordering).  Three
  consequences: (1) the GC never relocated any dlocal-SAVED pop value
  -- restores wrote stale pre-GC heap addresses back into cells like
  `cucharout` (every print after an unlucky GC then walked garbage);
  (2) `Copyscan` treated non-pop dlocal saves as pop pointers;
  (3) `M_PD_SAVES_NEXTFREE` zeroing hit the wrong slot.
* **Why it hid:** the system dlocals usually hold immovable seed
  values; it only bites when a *movable* heap value is dlocal-saved
  across a GC (e.g. lisp output streams in `cucharout`).  In practice
  this was the long-standing "Copyscan flakiness under compile load"
  on arm64.
* **Reproducer (fails on unfixed arm64 Linux):**
  ```
  vars keep r;
  identfn(% 1, 2 %) ->> keep -> cucharout;
  sysgarbage();
  cucharout -> r; charout -> cucharout;
  keep == r =>     ;;; <false> when broken, <true> when fixed
  ```
* **Fix:** assign/restore dlocal slots descending in
  `M_CREATE_SF`/`M_UNWIND_SF`.

### A2. ext_arm.c: K_EXTERN_TYPE read at the wrong key offset
`pop/extern/lib/ext_arm.c` (all arm64).

`ET_OFF` was 98, mis-counting the two `int` key fields as `full`s;
the 64-bit layout puts `K_EXTERN_TYPE` at 2x4 + 10x8 + 2 = **90**.
Offset 98 reads a byte of `K_CONS_R` (non-zero for most keys), so
*every* compound external argument classified as "dereference":
external pointers worked by accident, exfunc closures were passed by
content, and `ET_DDEC` never matched -- ddecimal (float) arguments to
C functions have never worked on arm64.  Verified against the key
records in a built image (+90: exfunc=0/NORMAL, exptr=1/DEREF).

### A3. external.ph: EFC_CODE_SIZE wrong for aarch64
The aarch64 exfunc-closure template (asm_gen_exfunc_clos_code) emits
4 xwords; `EFC_CODE_SIZE` stayed 16, leaving `EFC_ARG`/`EFC_ARG_DEST`
*inside the code*.  C->Pop callbacks could never have worked on arm64
(unexercised: arm64 Linux builds -nox, and X callbacks are the main
consumer).  With A2+A3, the callback chain passes end-to-end:
`exfunc_export` closure called from C, multiple round trips.

### A4. ass.p: literal-pool buffer overflow at the 257th literal
`Do_consprocedure` allocated `lit_buff = initintvec(512)` -- 32-bit
elements, 2048 bytes -- while `load_literal` indexes it as 64-bit
words.  Literal #257+ overflowed onto the adjacent heap object; the
`_lt _512` cap was the coincidence 512x4 == 256x8.  Rare on Linux
(MOVZ/MOVK covers most values) but reachable; hot on any port with
high address ranges.  Fix: `initlongvec(2048)`.

### A5. procedure.p: Flush_procedure wild range for shared-code closures
(platform-independent)  Flush length = record-end - `PD_EXECUTE` is
wild (observed 545GB) for closures whose `PD_EXECUTE` points outside
their own record (shared template code).  Harmless by luck on compact
ELF layouts; faults on Darwin.  Fix: skip unless `PD_EXECUTE` lies in
`[record, record+PD_LENGTH)` -- shared code was flushed at creation.

### A6. ass.p: pass-0 measures with zero _pdr_offset/_strsize
Instruction *selection* depends on both (I_CREATE_SF immediate forms,
PB-relative load forms); large structure tables make the measured and
planted streams diverge, mis-addressing every pool-relative LDR.  The
re-measure (pass 0b) is gated `DEF DARWIN` here because only Darwin's
address ranges force pooled literals everywhere; the bug is latent on
ELF and upstream may prefer it ungated.

### A7. lisp/clos.p: mid-file autoload re-imports cancelled words
(platform-independent)  `clos.p` cancels `define_method` etc., then
references autoloadable `ncrev`; the autoload's section round-trip
re-imports the cancelled globals and the later constant declaration
mishaps.  Fix: `uses` the dependencies before the `syscancel`.  (On
some builds the autoload silently fails instead, leaving a latent
broken CLOS -- worth checking any lisp build.)

### A8. init_args.p: relocatable saved images
(platform-independent improvement)  Layered images record their base
images' absolute save-time paths, so a moved installation cannot
restore `clisp.psv` etc.  `Init_arg_search` now falls back to
searching the bare filename along its dir_list (popsavepath) when a
recorded path is missing.  This is what makes store/packaged installs
(Nix, relocatable tarballs) work.

### A9. os_comms.p: POP__ranlib override
`/usr/bin/ranlib` was hardcoded (POP__as/POP__ar already had env
overrides).  Needed by any hermetic build environment.

### A10. ext_arm.c: two FP-argument marshalling bugs (all arm64)
`pop/extern/lib/ext_arm.c` -- both latent on arm64 Linux too; they
only bite when an external call passes **two or more** floating-point
arguments, which almost nothing in the core does.  The native graphics
layer (many `float` coordinates per call) is the first heavy user and
exposed both.  A direct regression is `tools/ffi-float-regression.p`
(`pow`/`atan2`/`hypot`/`cbrt`); it fails on either bug.

* **f_reg register-buffer stride.**  The hand-written caller
  (`pop/src/arm64/aextern.s`) loads `d0`-`d7` from the register buffer
  at a **16-byte** stride -- it reserves `8*16` bytes, the full q0-q7
  vector-register width (its own "8*8 + 8*16 = 192 byte" comment).  But
  `reg_buff` declared `double f_reg[8]` at an **8-byte** stride, so `d1`
  read slot 2, `d2` read slot 4, ... and *every other* FP argument was
  silently dropped.  `pow(2,10)` came back `pow(2,0)=1`.  Fix: make each
  FP slot 16 bytes wide (`struct { double d; uint64_t _pad; } f_reg[8]`).

* **boxed-ddecimal read offset.**  A ddecimal's 64-bit double `DD_1`
  lies two words before the structure pointer (layout
  `word DD_1; full KEY; >->` in `syscomp/symdefs.p`; `KEY` is the
  `ai[-1]` word the A2 type-byte read already relies on).
  `x86_64/aextern.s` reads it as `_DD_1(ptr) = @@DD_1`; this code read
  at **offset 0** instead -- the *following* heap object's first word --
  so every `double`-valued external argument read the wrong value
  (`cbrt(27)` -> `0`).  Fix: read at `ai - 2*sizeof(uint64_t)`.

The Pop-side type spec matters too: Poplog passes (d)decimals as
**double** by default (REF * EXTERNAL 5.2), so a C glue routine taking
ANSI `float` needs each such argument flagged `<SF>` -- `popgfx.p` now
does this for every coordinate.  (A2 noted "ddecimal float arguments
have never worked on arm64"; A10 is the rest of that story -- with A2 +
A10 + `<SF>`, single and double FP arguments both pass correctly.)

---

## B. Performance: both backends are good; here is the data

Measured with `tools/bench-poplog.p` (identical workloads; see
BENCHMARKS.md for full tables and methodology, including a correction
worth reading: an aarch64 binary silently executed by binfmt_misc
under qemu initially masqueraded as a slow "native x86-64" build.
**There is no x86_64 backend problem** -- the genuine x86-64 build is
the fastest configuration we measured, and the arm64 backend is
within ~2x of it on far weaker silicon).

| native build | nfib29 | intloop10M | closures1M |
|---|---|---|---|
| i7-9700K x86-64 | 1 | 7 | 3 |
| Apple M2 arm64 (this port) | 2 | 5 | 3 |
| Raspberry Pi 5 arm64 | 2 | 12 | 4 |

(centiseconds; Poplog leads the best CPython build 5-10x on every
platform on these workloads.)

The macOS port's performance required one arm64-Darwin-specific design
(Phase 4: `PD_EXECUTE` biased into an RX alias of the W^X heap, ~280x
on call-heavy code) which is documented in
PORTING-ARM64-M-SILICON-OSX.md and may interest anyone porting to
other W^X-enforcing platforms.

On AArch64 tuning generally: the meaningful wins on this branch came
from correctness of the runtime contracts (A1-A6) and from OS-layer
mechanics, not from instruction-selection tuning; the generated-code
style of the arm64 backend matches the x86-64 backend closely (we
diffed popc output instruction-for-instruction) and benchmarks bear
both out.

---

## C. Where things live

* Every fix above is an isolated commit on this branch with a full
  rationale in its commit message (`git log --grep="refs #12"`).
* Validation: `tools/validate-raspi5.sh` (arm64 Linux, 12 gates),
  `tools/validate-msilicon.sh` (macOS), `tools/validate-gfx.sh`
  (graphics), `tools/bench-poplog.sh` (benchmarks; prints the
  engine's `file` output -- check it).
* The macOS port itself, the Nix packaging (`flake.nix`,
  `nix/README.md`), and the native graphics backend are offered as a
  whole; the A-series fixes stand without them.


## Changing anything under `pop/src`

`poplink` links two libraries built from `pop/src`: `target/obj/src.wlb`
(Poplog word files) and `target/obj/src.olb` (machine code — including the
hand-written `pop/src/<arch>/*.s`).  `poplibr` *updates* a library rather
than recreating it, so both halves must be deleted before a rebuild or a
stale member silently shadows the new one: the build succeeds, the engine
relinks, and the old code keeps running.  `make` now removes both
(`stamp_srclib`, `stamp_vedlib`, `stamp_xlib`), but if you are driving the
steps by hand, delete `target/obj/*.olb` too.

Do not take a changed binary as evidence that a change landed — `poplink`
stamps a build date into every image, so the checksum moves on every relink.
Check for the code itself, or for a behavioural difference from a fresh
engine.  See `docs/bugs/stale-olb-shadows-rebuild.md`.

## Build snapshots (poplog-builds)

Built trees are archived in the public, versioned bucket `poplog-builds`
(`us-west-1`), one object per snapshot plus its sha256 and a manifest:

    https://poplog-builds.s3.us-west-1.amazonaws.com/builds/<platform>/

Seeds and skill tarballs stay on GitHub Releases; this bucket is for the
*built* tree (`target/pop`, `target/psv`, `target/obj`, `stamp_*`) — the
thing that takes an hour to reproduce on a slow board and, on riscv64 in
September 2026, could not be reproduced at all.  After every green
`validate-*.sh`:

    tools/snapshot-build.sh <platform> good

To restore: fetch the `.tgz`, check it against the `.sha256`, untar into the
repo root.  Read the manifest first — it records kernel, glibc, compiler
and the git sha the sources matched, which is exactly what was missing when
machine1's build went bad.
