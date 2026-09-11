# sys_file_stat returns the wrong fields on aarch64 and riscv64 Linux

Found 2026-08-19 while verifying the Emacs/swank work on `raspi5`
(DietPi, Linux 6.18 aarch64).  **Not fixed** -- see "The fix that didn't
take" below.  Pre-existing; nothing in the Emacs, swank or jsonrpc work
touches this code.

## Symptom

`sys_file_stat` fills its result vector from the wrong offsets.  Element 1
is documented as the byte size and comes back as the block size instead:

    $ printf 'hello\nworld\n' > /tmp/sz12      ;;; 12 bytes
    sys_file_stat('/tmp/sz12', initv(8)) =>

| element | means | Linux aarch64 | macOS arm64 | real value |
| --- | --- | --- | --- | --- |
| 1 | size | `16384` | `12` | 12 |
| 2 | mtime | `517399541` | `1787127174` | 1787127167 |
| 4 | uid | `0` | `501` | 1000 |
| 5 | mode | `33188` | `33188` | 33188 |
| 6 | nlink | `4294967297000` | `1` | 1 |
| 8 | inode | `11730` | -- | 11730 |

Every value is explained by an eight-byte shift that starts at `st_nlink`:

  * 16384 is this filesystem's `st_blksize` (offset 56, where the
    declaration puts `ST_SIZE`),
  * 517399541 is the mtime *nanoseconds*, not the seconds,
  * 4294967297000 is `1000 + 1000 * 2**32` -- uid and gid read together as
    one 64-bit field,
  * fields before nlink (dev, ino, mode) are all correct.

## What it breaks

  * `file_size` and `file_mtime` in LIB * FILEUTILS, which are thin
    wrappers over elements 1 and 2 -- `tools/tests/test_fileutils.p` fails
    its `file_size` check.
  * `zm_load_story`, which sizes its buffer from the file size -- the whole
    of `tools/tests/test_zmachine.p` fails with "story file shorter than
    its header says: 10380 4096".
  * Anything else that asks the system how big a file is.

Unaffected: Linux x86_64 and macOS arm64, both of which pass these suites.

## Cause

`pop/src/unixdefs.ph` gives every Linux the same basic types:

    #_ELSEIF DEFV LINUX >= 2.0
    deftype
        ...
        nlink_t = long,     ;;; 64 bits on a 64-bit target

That is right for x86_64, whose `struct stat` really does widen `st_nlink`
to a 64-bit unsigned long.  arm64 and riscv64 take their layout from
`<asm-generic/stat.h>` instead, where `st_nlink` is 32 bits sitting
immediately after the 32-bit `st_mode`.  Declaring it 64 bits costs four
bytes of padding plus four bytes of width, and every field after it lands
eight bytes late.

Both architectures share the declaration: `pop/src/syscomp/riscv64/sysdefs.p`
sets `ARM64_LINUX = true` deliberately, so that the shared headers apply.

riscv64 was confirmed on 2026-08-19 against a **freshly built** engine
(current `dev`, StarFive VisionFive, Ubuntu 6.5), so this is not an
artefact of the stale engine that host used to carry:

| element | means | riscv64 | real value |
| --- | --- | --- | --- |
| 1 | size | `4096` (the blksize) | 12 |
| 2 | mtime | `708869249` (nanoseconds) | 1787…  |
| 5 | mode | `33188` | 33188 |
| 6 | nlink | `43001212572599` | 1 |
| 8 | inode | `369274` | 369274 |

`test_fileutils` fails its `file_size` check and `test_zmachine` fails to
load its story file, exactly as on aarch64.

## The fix that didn't take

The obvious patch is to split the arm64 case out of the branch at
`unixdefs.ph:314` and declare the field 32 bits wide:

    #_IF DEF ARM64_LINUX
        mode_t  ST_MODE;        /* u32  @16  */
        int     ST_NLINK;       /* u32  @20  */

On paper that puts `ST_SIZE` back at offset 48, and the arithmetic checks
out against the observed values.  It does not work, and the reason is not
the struct.

**Edits to `pop/src/sys_file_stat.p` do not reach the built engine at
all.**  That was established on 2026-08-19 with a marker: four
`cucharout` calls at the top of the procedure, after `Check_vector`, so
every call would print.  The marker compiles (the `.w` grows by exactly
the right amount and the fresh member is present in `src.wlb`), the
engine relinks, and at runtime the marker never prints -- zero
occurrences in the full output, not merely the head of it.

The same is true of the struct: adding a deliberate `int ST_XPAD_PROBE;`
after `ST_NLINK` shifts nothing at runtime.  Nothing about that file
reaches the engine.

Ruled out along the way:

  * **Saved images.**  Same results under `%nort %noinit`, and the `.psv`
    files are rebuilt anyway.
  * **A shadowing autoloadable.**  `sys_file_stat.p` exists exactly once
    in the tree, and the running procedure reports `pdprops` of
    `sys_file_stat`, 2 arguments, not a closure.
  * **A second definition.**  Only `pop/src/sys_file_stat.p:27` defines it.
  * **Stale intermediates.**  `target/src/*.[ow]` were deleted and
    regenerated; `stamp_srclib` also removes them itself.
  * **A missing header dependency.**  `Makefile.in:178` already lists
    `$(wildcard pop/src/*.ph)` in `SRC_SRC`, and `all` does reach
    `stamp_srclib` by way of `stamp_vedlib`.
  * **A stale seed.**  A full bootstrap in the order `INSTALL` prescribes
    -- `make stamp_new_corepop`, `mv new_corepop corepop`, then a clean
    `make all` -- changes nothing.

A caution for anyone continuing: **the build is not reproducible**, so
comparing md5 sums of `.o`, `.w` or `basepop11` between two builds proves
nothing.  Two consecutive batch compiles of the same unchanged source
gave `146c1b12…` and `627973ea…` for `sys_file_stat.o`.  An earlier round
of this investigation was misled by exactly that, comparing the
443-byte `.w` symbol table (which happened to be stable) and concluding
the declaration had no effect on codegen.  It does: a single-file
recompile with the field narrowed changes 1429 bytes of the `.o`.  Only
runtime behaviour is trustworthy evidence here.

So the open question is no longer "what is the right declaration" -- it
is **how base-system procedures actually get into `basepop11`**, given
that recompiling one and relinking demonstrably does not replace it.
`popc -c -nosys` and how `poplink` chooses between `vedsrc.wlb` and
`src.wlb` (both name `sys_file_stat`; only `src.wlb` should define it)
are the places to look.

Reproduce the bug with:

    printf 'hello\nworld\n' > /tmp/sz12
    stat -c 'size=%s blksize=%o nlink=%h uid=%u' /tmp/sz12
    ;;; then, in Pop-11:
    sys_file_stat('/tmp/sz12', initv(8)) =>
