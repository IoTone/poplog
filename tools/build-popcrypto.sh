#!/bin/sh
# build-popcrypto.sh — build the libcrypto shim used by LIB * CRYPTO.
#
#   tools/build-popcrypto.sh
#
# Compiles pop/extern/popcrypto/popcrypto_shim.c to popcrypto.{so|dylib}
# in the same directory (where pop/lib/lib/crypto.p exloads it from).
# Needs a C compiler and the OpenSSL development headers (Debian/Ubuntu:
# libssl-dev; macOS: brew install openssl, or use the system headers).
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/pop/extern/popcrypto/popcrypto_shim.c"

# LIB * CRYPTO picks the .dylib over the .so when both exist, so a
# stale artifact from the other platform (a tree rsynced from a Mac to Linux,
# say) silently shadows the one we are about to build and the load fails with
# "can't find value for symbol".  Clear the other platform's file.
case "$(uname -s)" in
    Darwin) lib="$repo/pop/extern/popcrypto/popcrypto.dylib"
            rm -f "$repo/pop/extern/popcrypto/popcrypto.so" ;;
    *)      lib="$repo/pop/extern/popcrypto/popcrypto.so"
            rm -f "$repo/pop/extern/popcrypto/popcrypto.dylib" ;;
esac

if [ -f "$lib" ] && [ ! "$src" -nt "$lib" ]; then
    echo "up to date: $lib"
    exit 0
fi

command -v cc >/dev/null 2>&1 || { echo "build-popcrypto: needs a C compiler" >&2; exit 2; }

# pkg-config knows about Homebrew/non-standard OpenSSL locations
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libcrypto 2>/dev/null; then
    flags="$(pkg-config --cflags --libs libcrypto)"
else
    flags="-lcrypto"
fi

# HMAC() is deprecated-but-present in OpenSSL 3; it is the portable
# one-shot (also on LibreSSL), so silence the advisory
# shellcheck disable=SC2086
cc -O2 -shared -fPIC -Wno-deprecated-declarations -o "$lib" "$src" $flags
echo "built $lib"
