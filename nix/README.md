# Nix packaging

Build and run Poplog with Nix (flakes):

```sh
nix build .#poplog          # or: nix build path:$PWD#poplog in a non-git tree
./result/bin/pop11          # Pop-11 REPL
./result/bin/clisp          # Common Lisp
./result/bin/prolog         # Prolog
./result/bin/pml            # Standard ML
./result/bin/ved file       # terminal VED
```

## Build cost (first build)

Nix builds Poplog **and its toolchain closure** from source, substituting
prebuilt dependencies from the binary cache. Budget for it the first time:

* **Download** — roughly **~1.1 GB** of dependencies (clang/stdenv, ncurses,
  perl; plus SDL3 + Mesa for `poplog-gfx` on Linux, or the ImGui FOD).
  Cached afterward — rebuilding the same source fetches nothing.
* **Disk** — the realized runtime closure is **~1.2 GiB** (the Poplog
  out-path itself is only ~95 MB; the rest is the shared dependency closure
  that other Nix builds reuse).
* **Time** — about **2 minutes** of build on a fast machine (Poplog
  bootstraps from the seed `corepop`, then builds the four language images),
  plus the one-time download.

A *source* edit re-runs the full bootstrap — the build is not incremental
across `nix build`. For iterative hacking use `nix develop` (below).

## Use cases

The flake exposes `packages`, `apps`, and a `devShell`:

```sh
# Run a language front-end directly (no checkout needed):
nix run .#pop11             # or .#prolog .#clisp .#pml .#ved
nix run .                   # bare run starts the Pop-11 REPL
echo '6 * 7 =>' | nix run .#pop11        # ** 42

# Ephemeral shell with every front-end on PATH:
nix shell .#poplog -c pop11 myfile.p

# Dev shell for hacking on Poplog sources:
nix develop                 # pop11/clisp/prolog/pml/ved on PATH, $usepop set
```

Compiling a source file: use a front-end (`pop11 file.p`), not the bare
`basepop11` -- run with no subsystem, `basepop11` looks for its own
startup file and reports `basepop11.p` not found. `exload`/`exacc`
(calling C from Pop) works from the store build: it shells out to the
system compiler at run time, so a C toolchain must be on PATH (on macOS
`/usr/bin/clang` always is).

Supported systems: `x86_64-linux` and `aarch64-darwin` (both tested
end-to-end: all four languages run from the store path — and the
`poplog-gfx` graphics variant builds on both), and `aarch64-linux` (seed
vendored from a validated RPi5 build; flake untested -- no aarch64-linux
Nix host yet).

macOS note: no entitlements are required -- the W^X machinery uses
mach_vm_remap + mprotect on anonymous pages, not MAP_JIT, so the
linker's ad-hoc signature suffices (the link epilogue refreshes it
when a codesign is available, and tolerates its absence).

## Experimental graphics

`poplog-gfx` builds basepop11 with the native graphics backend
(`--experimental-graphics` -> Dear ImGui).  It is provided for **every
supported system**; `./configure` picks the backend per platform:

* **macOS** (`aarch64-darwin`) — **Metal + Cocoa**.  The frameworks come from
  the Darwin stdenv SDK, so no extra inputs are needed; the binary links
  `Metal`/`MetalKit`/`Cocoa`/`QuartzCore`/`GameController`.
* **Linux** — **SDL3 + OpenGL3**.  SDL3 (3.2.20) is why the flake pins
  nixpkgs 25.05.

Either way the ImGui source is fetched as a `fetchFromGitHub` FOD (the
in-tree `pop/extern/imgui/` is gitignored and the sandbox has no network).

```sh
nix build .#poplog-gfx          # Metal on macOS, SDL3 + OpenGL3 on Linux
nm result/poplog/target/pop/basepop11 | grep -c pop_gfx   # 26 (Metal) / 27 (SDL3)
otool -L result/poplog/target/pop/basepop11 | grep Metal   # macOS: framework linked
echo "uses rc_graphic; rc_start();" | result/bin/pop11     # opens a window
```

On **macOS** the graphics binary links the system Metal/Cocoa frameworks and
just runs — no driver injection or display server to arrange.

On **Linux** the binary links nix's `libSDL3` + `libglvnd`; **SDL3 picks the
display transport at run time** (Wayland if `WAYLAND_DISPLAY`, else X11, else
`kmsdrm`) -- there is no hard X11 dependency.

Running the Linux build needs a GL driver `libglvnd` can reach:

* **NixOS** -- seamless; the configured GPU driver is wired into the GL
  stack (`hardware.graphics.enable`).  This is the smooth path.
* **Non-NixOS (Ubuntu, etc.)** -- the system GPU driver lives outside the
  nix store, so a nix GL binary needs the driver injected, the usual way
  being [nixGL](https://github.com/nix-community/nixGL):
  `nixGL result/bin/pop11 myfile.p`.
* **Headless / CI** -- software render with Mesa llvmpipe over EGL
  (`SDL_VIDEO_X11_FORCE_EGL=1 LIBGL_ALWAYS_SOFTWARE=1`), no GPU required.

The SDL3+OpenGL3 backend itself is verified rendering the full Poplog
surface (lines/rects/circles/arcs/text + ImGui panels) on Linux/X11.
The `nix build` is verified end-to-end (console smoke passes from the
store path); driving its GL on a given box is the standard nix-graphics
deployment story above.

## Bootstrap seeds

Poplog builds itself with a prior binary `corepop`; per-platform seeds
are vendored under `nix/seeds/corepop-<system>` and patchelf'd so they
can run inside the build sandbox (they link only libc/libm/libdl).
Any previously built corepop for the platform works as a seed -- to
refresh one, copy `target/pop/new_corepop` from a successful build.
When release artifacts exist, replace the vendored files with
`fetchurl` fixed-output derivations in `nix/poplog.nix` (`seed`).

### Provenance

Each seed is built from a clean checkout of the commit it is vendored
in, bootstrapped from the seed it replaces, and accepted only after a
full `tools/ci/build-and-verify.sh` from it passes.

| seed | sha256 | from commit | built on | date |
| --- | --- | --- | --- | --- |
| `corepop-x86_64-linux` | `c3735331` | (upstream) | -- | -- |
| `corepop-aarch64-linux` | `285286f6` | `424643f` | Raspberry Pi 5, DietPi | 2026-10-14 |
| `corepop-riscv64-linux` | `f7ab20d5` | `424643f` tree | Cloud-V riscv64 host | 2026-10-14 |
| `corepop-aarch64-darwin` | `491a744c` | `424643f` | Apple Silicon macOS | 2026-10-14 |

The three non-x86 seeds were re-blessed together because each predated
the `struct STATB` layout fix for its platform, and a stale seed is not
merely old: `popc`, `poplink` and `poplibr` are symlinks to `corepop`
(`Makefile.in:151-152`) and `sys_file_stat` is a built-in of the running
binary, so the librarian stamps library members with dates read through
the *seed's* layout.  With a pre-fix seed those dates were nanosecond
counts -- members of a library built this afternoon listed as 1996 --
which makes every incremental staleness decision meaningless.  See
`docs/bugs/aarch64-stat-layout.md`.

So when refreshing a seed, check it before vendoring it: `sys_file_stat`
on a file whose size is a multiple of no block size must return that
size and an mtime in living memory, and `poplibr -ld` on a freshly built
library must list today.

## Notes

* Hardening is disabled wholesale: Poplog generates and executes its
  own machine code and lays memory out at fixed addresses (no PIE).
* The build overrides `POP__as`/`POP__ar`/`POP__ranlib` -- the sandbox
  has no `/usr/bin/{as,ar,ranlib}`.
* Saved images record their base images' absolute save-time paths;
  the engine falls back to searching `popsavepath` by filename
  (`Init_arg_search`), which is what makes the store-installed images
  relocatable.
* Native graphics (`--experimental-graphics`) is wired into the Nix build
  on **both** platforms via `poplog-gfx` — Metal/Cocoa on macOS, SDL3 +
  OpenGL3 on Linux.
