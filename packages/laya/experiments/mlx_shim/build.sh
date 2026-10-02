#!/bin/sh
# build.sh MLX_C_DIR -- build pm_shim.dylib (E5) and pm_ops.dylib (E4) against an mlx-c checkout built as a shared
# library (cmake -DMLX_C_USE_SYSTEM_MLX=ON -DBUILD_SHARED_LIBS=ON, against the venv's MLX).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
mlxc="$(cd "$1" && pwd)"
for name in pm_shim pm_ops; do
    clang -O2 -shared -fPIC -Wall -o "$here/$name.dylib" "$here/$name.c" \
        -I"$mlxc" -L"$mlxc/build" -lmlxc -Wl,-rpath,"$mlxc/build"
    echo "$here/$name.dylib"
done
