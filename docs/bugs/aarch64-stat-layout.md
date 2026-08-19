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
So riscv64 has the same bug, and this may be the real reason
`test_fileutils` behaved badly there (see `linux-socket-options.md`, where
it was put down to a stale engine).

## The fix that didn't take

The obvious patch is to split the arm64 case out of the branch at
`unixdefs.ph:314` and declare the field 32 bits wide:

    #_IF DEF ARM64_LINUX
        mode_t  ST_MODE;        /* u32  @16  */
        int     ST_NLINK;       /* u32  @20  */

On paper that puts `ST_SIZE` back at offset 48.  It does not work, and the
reason is not yet understood.  What was established:

  * The branch is live.  Replacing its body with a deliberate syntax error
    fails the build with "POPC: ERROR IN struct (unknown type specifier)",
    so popc really is reading these lines for this target.
  * The rebuild is real.  Deleting `target/src/*.w` and `*.o` and the stamp
    files, then `make all`, regenerates both and relinks `basepop11`
    (confirmed by its embedded build date).
  * The output is identical either way.  `target/src/sys_file_stat.w` has
    md5 `09e8691424ba31fbf60b7c4207b6e2f8` whether the field is declared
    `nlink_t` or `int`, and the runtime behaviour is unchanged.

Identical object output means the declared width is not actually changing,
which points at how popc resolves the named types rather than at the
struct: `long` is `T_LONG`, which is `t_INT` when `LONG_BITS == INT_BITS`
and `t_DOUBLE` otherwise (`pop/src/syscomp/syspop.p:248`), with the widths
coming from `defcm` defaults in `mcdata.p` that a target's `sysdefs.p` may
or may not have overridden by that point.  That interaction is where to
look next.  Note also that a correct answer has to keep dev/ino/mode right,
which the current declaration already gets right -- so whatever is going on
is specific to how `nlink_t` resolves.

Reproduce with:

    printf 'hello\nworld\n' > /tmp/sz12
    stat -c 'size=%s blksize=%o nlink=%h uid=%u' /tmp/sz12
    ;;; then, in Pop-11:
    sys_file_stat('/tmp/sz12', initv(8)) =>
