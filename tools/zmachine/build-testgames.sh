#!/bin/sh
# build-testgames.sh — compile the Z-machine test story files from source.
#
#   tools/zmachine/build-testgames.sh
#
# Products land in examples/games/ and ARE committed, so neither CI nor a
# contributor needs an Inform toolchain to run the test suite; this script
# exists to make them reproducible.
#
# Needs Inform 6 (the `inform` binary):   brew install inform6
#                                         apt install inform
#
# CZECH compiles for several Z-machine versions; we build the ones the
# interpreter targets.  On v3 a correct interpreter reports:
#     Performed 368 tests.  Passed: 349, Failed: 0, Print tests: 19
set -e

repo="$(cd "$(dirname "$0")/../.." && pwd)"
games="$repo/examples/games"
cd "$games"

command -v inform >/dev/null 2>&1 || {
    echo "build-testgames: no 'inform' binary (brew install inform6)" >&2
    exit 2
}
inform -h 2>&1 | head -1

# -v3 selects Z-machine version 3.  The `Switches e` line in czech.inf is
# deprecated in modern Inform and warns; that is expected and harmless.
inform -v3 czech.inf czech.z3
echo "built: examples/games/czech.z3 ($(wc -c < czech.z3 | tr -d ' ') bytes)"

# Sanity: byte 0 of a story file is its version number.
v="$(od -An -tu1 -N1 czech.z3 | tr -d ' ')"
[ "$v" = 3 ] || { echo "build-testgames: czech.z3 is version $v, expected 3" >&2; exit 1; }
