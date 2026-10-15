# sys_file_stat returns the wrong fields on aarch64 and riscv64 Linux

Found 2026-08-19 while verifying the Emacs/swank work on `raspi5`
(DietPi, Linux 6.18 aarch64).  **Fixed** 2026-10-14 in `unixdefs.ph`, on both affected architectures --
by the very patch "The fix that didn't take" below reports as ineffective.
Nothing was wrong with that patch; see "Why it takes now".  Pre-existing;
nothing in the Emacs, swank or jsonrpc work touches this code.

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

## Why it takes now

The patch above was right.  What defeated it was `docs/bugs/stale-olb-shadows-rebuild.md`,
found a month later on 2026-09-16: `popc` writes a `.w` and a `.o`,
`poplibr` archives them into `src.wlb` and `src.olb`, and **`src.olb` was
never cleaned**, so a rebuilt member joined the archive alongside the old
one and the stale member won at link time.  That is precisely the reported
symptom here -- the compile succeeds, the `.w` grows by the right amount,
the fresh member is present, the engine relinks, and the behaviour does
not change.  It explains the `cucharout` markers that never printed, and
it explains why deleting `target/src/*.[ow]` did not help: the shadow was
in `target/obj/src.olb`, which that step leaves alone.  The stale-olb note
predicted this ("almost certainly the same wall hit in commit 68398fc"),
and it was right.

So the open question that section ends on -- "how base-system procedures
actually get into `basepop11`" -- is answered, and not by anything exotic:
they get in correctly, and an uncleaned archive was serving an older copy.

Two things made the difference on 2026-10-14:

  * the `Makefile.in` fix for the stale `.olb`, and
  * CI now making **every** engine rebuild a clean rebuild (commit
    `95eb77e`): `target`, `stamp_*`, `Makefile` and `./poplog` are removed
    and the tree rebuilds from the corepop seed.  A content fingerprint over
    `pop/src`/`pop/extern` plus `Makefile.in` and `configure` triggers it,
    so editing a `.ph` -- exactly this fix -- forces the clean rebuild
    rather than an incremental one.

Verified on `dietpi5-kordshom` (Pi 5, DietPi, 16K pages) with a clean
rebuild from the seed: all ten `sys_file_stat` fields agree with `stat(1)`,
`test_fileutils` is 13/13, and `test_zmachine` loads its story file.

## Confirmed on riscv64 too

The declaration is shared -- `pop/src/syscomp/riscv64/sysdefs.p` sets
`ARM64_LINUX = true` on purpose -- so the one-line change covers riscv64 by
construction.  Verified there the same day on `machine1` (the board CI logs
call `riscv-cloud`), with a clean rebuild from the seed:

| element | means | before | after | `stat(1)` |
| --- | --- | --- | --- | --- |
| 1 | size | `4096` (the blksize) | `12` | 12 |
| 2 | mtime | nanoseconds | `1792029605` | 1792029605 |
| 3 | gid | -- | `10012` | 10012 |
| 4 | uid | -- | `5047` | 5047 |
| 6 | nlink | `43001212572599` | `1` | 1 |
| 8 | inode | `369274` | `359052` | 359052 |

`test_fileutils` passes 13/13 and the riscv64 skill tarball builds, installs
and smoke-tests clean.

`test_fileutils` was also added to the default pre-packaging gate in
`tools/ci/build-and-verify.sh` alongside `test_primitives`, so a layout
regression on any platform now fails the build before it can ship a
tarball -- it ran as part of the verification above.

## Lesson

Both wrong answers were plausible integers -- a size that looks like a
size, an mtime that looks like an mtime -- and the suite asserted only
`isintegral` of the latter.  A test that cannot tell a field from its
neighbour cannot catch a layout bug, so `test_fileutils` now uses a size
that is a multiple of no block size and requires the mtime to fall in
living memory rather than the 1970-2001 window a nanosecond count lands in.

## The seed kept the bug alive, and the engine fix never reached the librarian

Found 2026-10-14 while deciding whether to re-bless the vendored seed
corepops, and the reason that decision stopped being cosmetic.

`popc`, `poplink` and `poplibr` are symlinks to `corepop`
(`Makefile.in:151-152`), and `sys_file_stat` is a built-in of the running
binary, not of the `.psv` image it loads.  The librarian therefore reads
file dates through the *seed's* STATB layout no matter how correct the
sources are.  `poplibr_main.p:50` stamps every library member's
`WMH_DATE` from `stat_vec(2)` -- subscript 2 is MTIME (`pop/ref/sysio`)
-- and `:286` decides a source has changed with `date < stat_vec(2)`.

In a fully fixed tree, bootstrapped from the pre-fix seed:

    $ ./poplog poplibr -ld target/obj/termcap.wlb
    Fri Aug 23 13:54:19 PDT 1996  termcap.w          ;;; built that afternoon

and on riscv64 the members of `xsrc.wlb` list as 1979, 1984, 1990, 1997
and 1970 -- nanosecond counts read as epoch seconds, which land in
1970-2001.  So every library built on these platforms carried junk dates
and every staleness comparison against them was meaningless.  That is
precisely the symptom "Why it takes now" attributes to a stale
`src.olb`: correctness was being preserved only by the unconditional
clean (`Makefile.in:193`, `tools/ci/build-and-verify.sh:101-105`), which
throws the libraries away rather than trusting their dates.

Seeds rebuilt from `424643f` fix it:

    $ ./poplog poplibr -ld target/obj/termcap.wlb
    Wed Oct 14 22:39:38 PDT 2026  termcap.w

### All four vendored seeds were probed; three were wrong

A 16777-byte file (a multiple of no block size) dated 2026-01-02:

| vendored seed | size | mtime | uid | mode | verdict |
| --- | --- | --- | --- | --- | --- |
| `corepop-x86_64-linux` | 16777 | 1767323045 | 1000 | 0100644 | correct |
| `corepop-aarch64-linux` | 16384 | 0 | 0 | 0100644 | size is `st_blksize`, mtime is the nanoseconds |
| `corepop-riscv64-linux` | 16384 | 0 | 0 | 0100644 | same shift |
| `corepop-aarch64-darwin` | 1767351845 | 1767351845 | 0 | 501 | **different** shift: size reads mtime, mode reads uid |

macOS fails differently because Apple's 64-bit-inode layout puts 16-bit
`mode`/`nlink` *before* the inode (`unixdefs.ph:357-372`); the sources
have had that right since the offsets were commented, and a Sep-19
`basepop11` reads all ten fields correctly.  Only the seed was stale.

The shipped tarball contains no `corepop` and no `poplibr` (1,411
entries, none matching), so this was never user-facing -- installed
engines are built from fixed sources.  It is a maintainer-side defect
about which builds can be trusted to be incremental.
