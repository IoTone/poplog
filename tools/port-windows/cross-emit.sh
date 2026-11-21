#!/bin/sh
#
# cross-emit.sh -- on a host that already runs Poplog (any architecture),
# compile the system for x86-64 Windows as far as a non-Windows host can:
# popc and poplink run here and their assembler output is assembled into
# PE/COFF objects.  The C runtime and the final link happen on Windows with
# Cygwin's gcc.  See PORTING-X86-64-WINDOWS.md section 5.
#
# Needs: a seed corepop for THIS host at target/pop/corepop, ./configure
# already run, and binutils that target pe-x86-64 (Debian/Ubuntu package
# binutils-mingw-w64-x86-64; the object format is the same one Cygwin uses).
#
#   PE_PREFIX=/path/to/bin/x86_64-w64-mingw32-  tools/port-windows/cross-emit.sh
#
# Output, under target/win-cross/:
#   asm/              every assembler input popc and poplink produced
#   as-failures.log   assembler diagnostics, one block per failing file
#   link-command.txt  the link command poplink would have run
#   build.log         the full build output
# plus the real products in target/obj (src.olb, src.wlb) and target/pop
# (poplink_*.o, poplink_cmnd).
#
# A file the assembler rejects does not stop the run: an empty object stands
# in for it so that one pass lists every failure.  The result is then NOT
# linkable; check as-failures.log is empty before using the objects.
#
set -eu
cd "$(dirname "$0")/../.." || exit 2
[ -f Makefile ] || { echo "ERROR: run ./configure first." >&2; exit 2; }
[ -x target/pop/corepop ] || { echo "ERROR: no seed at target/pop/corepop." >&2; exit 2; }

PE="${PE_PREFIX:-x86_64-w64-mingw32-}"
"${PE}as" --version >/dev/null 2>&1 || { echo "ERROR: ${PE}as not found; set PE_PREFIX." >&2; exit 2; }

ROOT=$PWD
OUT=$ROOT/target/win-cross
rm -rf "$OUT"
mkdir -p "$OUT/asm"

cat > "$OUT/as-wrap" <<EOF
#!/bin/sh
# invoked as: as [options] -o OBJECT SOURCE
o=; prev=
for x in "\$@"; do [ "\$prev" = "-o" ] && o=\$x; prev=\$x; done
eval "src=\\\${\$#}"
[ -f "\$src" ] && cp "\$src" "$OUT/asm/\$(basename "\$src")"
if "${PE}as" "\$@" 2> "$OUT/as.err"; then
    exit 0
fi
{ echo "=== \$src"; head -40 "$OUT/as.err"; } >> "$OUT/as-failures.log"
[ -n "\$o" ] && "${PE}as" -o "\$o" /dev/null
exit 0
EOF
cat > "$OUT/cc-wrap" <<EOF
#!/bin/sh
echo "\$@" >> "$OUT/link-command.txt"
o=; prev=
for x in "\$@"; do [ "\$prev" = "-o" ] && o=\$x; prev=\$x; done
[ -n "\$o" ] && : > "\$o"
exit 0
EOF
chmod +x "$OUT/as-wrap" "$OUT/cc-wrap"
: > "$OUT/as-failures.log"

# Target OS for popc/poplink (see pop/src/syscomp/make_popc.p).  Set
# POP_TARGET_OS=linux to emit the Linux system through the PE assembler,
# which is only useful as a check of the object format.
export POP_TARGET_OS="${POP_TARGET_OS:-cygwin}"
export POP__as="$OUT/as-wrap"
export POP__ar="${PE}ar"
export POP__ranlib="${PE}ranlib"

rm -f stamp_popc stamp_srclib
{
    echo "--- stamp_popc";   make POP_arch=x86_64 stamp_popc
    echo "--- stamp_srclib"; make POP_arch=x86_64 stamp_srclib
    echo "--- pglink -core"
    (cd target/pop && POP__cc="$OUT/cc-wrap" "$ROOT/poplog" "$ROOT/scripts/pglink" -core)
} > "$OUT/build.log" 2>&1 || echo "BUILD STOPPED EARLY: see $OUT/build.log"

echo "target OS: $POP_TARGET_OS"
echo "assembler inputs captured: $(ls "$OUT/asm" | wc -l)"
echo "files the PE assembler rejected: $(grep -c '^=== ' "$OUT/as-failures.log" || true)"
echo "mishaps in build log: $(grep -ci mishap "$OUT/build.log" || true)"
ls -l target/obj/src.olb target/pop/poplink_cmnd 2>/dev/null || true
[ -f "$OUT/link-command.txt" ] && echo "link command captured" || echo "no link command captured"
