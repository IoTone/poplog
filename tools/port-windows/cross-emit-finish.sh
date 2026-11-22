#!/bin/sh
#
# cross-emit-finish.sh -- after cross-emit.sh has stopped on a compile error
# and the source has been fixed: recompile only the named files from pop/src,
# then build the libraries and run poplink.  Saves the 15 minutes a full
# cross-emit.sh run takes on a Raspberry Pi 5.
#
#   PE_PREFIX=... tools/port-windows/cross-emit-finish.sh extern_symbols.p ...
#
# Uses the wrappers and popc image cross-emit.sh left behind, so it must
# follow a cross-emit.sh run with the same POP_TARGET_OS.  A full run is
# still the only check that everything builds from clean.
#
set -eu
cd "$(dirname "$0")/../.." || exit 2
ROOT=$PWD
OUT=$ROOT/target/win-cross
[ -x "$OUT/as-wrap" ] || { echo "ERROR: run cross-emit.sh first." >&2; exit 2; }
PE="${PE_PREFIX:-x86_64-w64-mingw32-}"

export POP_TARGET_OS="${POP_TARGET_OS:-cygwin}"
export POP__as="$OUT/as-wrap"
export POP__ar="${PE}ar"
export POP__ranlib="${PE}ranlib"
: > "$OUT/as-failures.log"

{
    if [ $# -gt 0 ]; then
        echo "--- popc $*"
        (cd pop/src && "$ROOT/poplog" popc -c -nosys -od "$ROOT/target/src" "$@")
    fi
    echo "--- poplibr"
    rm -f target/obj/src.wlb target/obj/src.olb target/obj/termcap.wlb target/obj/termcap.olb
    (cd target/src &&
        "$ROOT/poplog" poplibr -c "$ROOT/target/obj/src.wlb" $(ls *.w | grep -v '^termcap\.w$') &&
        "$ROOT/poplog" poplibr -c "$ROOT/target/obj/termcap.wlb" termcap.w)
    echo "--- pglink -core"
    rm -f "$OUT/link-command.txt"
    (cd target/pop && POP__cc="$OUT/cc-wrap" "$ROOT/poplog" "$ROOT/scripts/pglink" -core)
} > "$OUT/finish.log" 2>&1 || echo "STOPPED EARLY: see $OUT/finish.log"

echo "word files: $(ls target/src/*.w | wc -l)   sources: $(cd pop/src && ls x86_64/*.s x86_64/*.p *.p | wc -l)"
echo "files the PE assembler rejected: $(grep -c '^=== ' "$OUT/as-failures.log" || true)"
echo "mishaps: $(grep -c 'MISHAP' "$OUT/finish.log" || true)"
ls -l target/obj/src.olb target/pop/poplink_cmnd 2>/dev/null || true
[ -f "$OUT/link-command.txt" ] && echo "link command captured" || echo "no link command captured"
