#!/bin/sh
# build-popcurl.sh — build the libcurl shim used by LIB * HTTP_CLIENT.
#
#   tools/build-popcurl.sh
#
# Compiles pop/extern/popcurl/popcurl_shim.c to popcurl.{so|dylib} in
# the same directory.  Needs a C compiler and the libcurl development
# headers (Debian/Ubuntu: libcurl4-openssl-dev; macOS: system curl).
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/pop/extern/popcurl/popcurl_shim.c"

# LIB * CURL picks the .dylib over the .so when both exist, so a
# stale artifact from the other platform (a tree rsynced from a Mac to Linux,
# say) silently shadows the one we are about to build and the load fails with
# "can't find value for symbol".  Clear the other platform's file.
case "$(uname -s)" in
    Darwin) lib="$repo/pop/extern/popcurl/popcurl.dylib"
            rm -f "$repo/pop/extern/popcurl/popcurl.so" ;;
    *)      lib="$repo/pop/extern/popcurl/popcurl.so"
            rm -f "$repo/pop/extern/popcurl/popcurl.dylib" ;;
esac

if [ -f "$lib" ] && [ ! "$src" -nt "$lib" ]; then
    echo "up to date: $lib"
    exit 0
fi

command -v cc >/dev/null 2>&1 || { echo "build-popcurl: needs a C compiler" >&2; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libcurl 2>/dev/null; then
    flags="$(pkg-config --cflags --libs libcurl)"
else
    flags="-lcurl"
fi

# shellcheck disable=SC2086
cc -O2 -shared -fPIC -o "$lib" "$src" $flags
echo "built $lib"
