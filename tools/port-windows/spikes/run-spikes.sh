#!/bin/sh
# Build and run the Windows-port spikes (PORTING-X86-64-WINDOWS.md section 9).
# Run from a Cygwin shell:  sh tools/port-windows/spikes/run-spikes.sh
# Output goes to the terminal; build products go to a temporary directory.
cd "$(dirname "$0")" || exit 2
out="${TMPDIR:-/tmp}/poplog-spikes.$$"
mkdir -p "$out" || exit 2
LOW="-Wl,--image-base=0x400000 -Wl,--disable-dynamicbase"

echo "== toolchain"
uname -srm
gcc --version | head -1
as --version | head -1

echo "== S3: default link (expected to reject 32-bit absolute relocations)"
if gcc -O1 -o "$out/s3_default" s3_main.c s3_abs.s 2> "$out/s3_default.err"; then
    echo "linked; running"
    (cd "$out" && ./s3_default)
    echo "exit $?"
else
    head -4 "$out/s3_default.err"
fi

echo "== S3: fixed low image base ($LOW)"
if gcc -O1 $LOW -o "$out/s3" s3_main.c s3_abs.s; then
    (cd "$out" && ./s3 64);  echo "exit $?"
    (cd "$out" && ./s3 400 | tail -5); echo "exit $? (400 MB touched)"
else
    echo "LINK FAILED"
fi

echo "== S1: fault recovery"
if gcc -O1 $LOW -o "$out/s1" s1_main.c s1_fault.s; then
    # The signal route loops for ever when it fails, hence the timeout.
    timeout 5 "$out/s1" sig 2>&1 | head -8
    echo "(cut off by timeout: it never recovered)"
    "$out/s1" veh;  echo "exit $?"
    echo "== S1: stack growth with unprobed 12 KB frames, default 2 MB stack"
    "$out/s1" deep 160;  echo "exit $?"
    "$out/s1" deep 200;  echo "exit $? (overflow: note the silent exit)"
    echo "== S1: the same with -Wl,--stack,0x10000000 (256 MB)"
    gcc -O1 $LOW -Wl,--stack,0x10000000 -o "$out/s1big" s1_main.c s1_fault.s
    "$out/s1big" deep 20000;  echo "exit $?"
else
    echo "BUILD FAILED"
fi

echo "== S2: symbolic links and .exe names"
cat > "$out/who.c" <<'EOT'
#include <stdio.h>
int main(int argc, char **argv) { printf("argv[0]=%s\n", argv[0]); return 0; }
EOT
gcc -o "$out/corepop" "$out/who.c"
ls "$out" | grep -i corepop
(cd "$out" && ln -s corepop popc && ls -l popc* | sed 's/.* popc/popc/' && ./popc)
(cd "$out" && mv corepop new_corepop && ls | grep -i corepop)

echo "== S2: .align and writing into .text"
cat > "$out/sec.s" <<'EOT'
    .text
    .globl  a0
a0: .byte   1
    .align  16
    .globl  a1
a1: .quad   7
    .globl  bump
bump:
    incq    a1
    movq    a1, %rax
    ret
EOT
cat > "$out/sec.c" <<'EOT'
#include <stdio.h>
extern char a0, a1; extern long bump(void);
int main(void) {
    printf(".align 16 advanced %ld bytes\n", (long) (&a1 - &a0));
    fflush(stdout);
    printf("write into .text gave %ld\n", bump());
    return 0;
}
EOT
echo "-- .text as the assembler makes it"
gcc $LOW -o "$out/sec" "$out/sec.c" "$out/sec.s" && "$out/sec"; echo "exit $?"
echo "-- .text marked writable in the object with objcopy"
gcc -c -o "$out/sec_s.o" "$out/sec.s" &&
objcopy --set-section-flags .text=code,alloc,load,contents "$out/sec_s.o" "$out/sec_w.o" &&
gcc $LOW -o "$out/secw" "$out/sec.c" "$out/sec_w.o" && "$out/secw"; echo "exit $?"
objdump -h "$out/secw.exe" | grep -A1 ' \.text'
rm -rf "$out"
