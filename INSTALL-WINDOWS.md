# Building Poplog on Windows 11

Poplog on Windows is a 64-bit Cygwin program: it is built with Cygwin's gcc
and GNU make from the same `configure` and `Makefile` as every other platform,
and it needs `cygwin1.dll` to run. It does not need WSL, Docker, MSYS2 or
Visual Studio. How the port works, and what has and has not been tested, is in
[`PORTING-X86-64-WINDOWS.md`](PORTING-X86-64-WINDOWS.md).

**Status (2026-11-20):** experimental, on the `windows-checkout` branch only.
It has been built and validated on one machine (Windows 11 Home build 26300,
Cygwin 3.6.12). The default branch does not check out on Windows.

The whole thing is five steps and about ten minutes, most of it the Cygwin
download.

## 1. Get the source

With ordinary Git for Windows, from PowerShell or `cmd`:

```
git clone --branch windows-checkout https://github.com/IoTone/poplog.git
cd poplog
```

Name the branch as shown. Line endings need no configuration.

## 2. Install the toolchain

From PowerShell, in the `poplog` folder:

```
powershell -ExecutionPolicy Bypass -File tools\port-windows\setup-cygwin.ps1
```

This downloads Cygwin's installer from cygwin.com, checks its signature, and
installs Cygwin to `C:\cygwin64` with the compilers and libraries Poplog uses.
It needs no administrator rights and adds no shortcuts. To install somewhere
else, add `-Root D:\cygwin64`. For a console-only build with the fewest
packages, add `-Minimal`.

If you already have Cygwin, run its `setup-x86_64.exe` yourself and add these
packages instead:

| For | Packages |
|---|---|
| any build | `gcc-core` `binutils` `make` `libncurses-devel` |
| graphics | `gcc-g++` `git` |
| LIB CRYPTO, LIB PCRE, LIB HTTP_CLIENT | `libssl-devel` `libpcre2-devel` `libcurl-devel` `pkg-config` |
| the pop11 skill (`popsession`, its SQLite shim) | `python3` `libsqlite3-devel` |
| the test runners, debugging | `perl` `curl` `gdb` |

Everything from here on is typed in a **Cygwin shell**, not PowerShell. Open
one with `C:\cygwin64\bin\bash.exe --login` (or the Cygwin Terminal), and go
to the source. Windows drives appear under `/cygdrive`:

```sh
cd /cygdrive/c/Users/YOU/poplog
```

## 3. Put the seed in place

Poplog is written in Pop-11, so building it needs a Poplog: a small
bootstrap binary called `corepop`. The one for Windows is in the tree, with
the other platforms' seeds:

```sh
mkdir -p target/pop
cp nix/seeds/corepop-x86_64-cygwin target/pop/corepop.exe
```

Note the `.exe` on the copy. The seed needs nothing but `cygwin1.dll`. It was
built from this branch and then checked by bootstrapping a fresh clone from
it alone; `PORTING-X86-64-WINDOWS.md` section 5 says how it was first made
(cross-compiled from a Linux machine) and how to make another.

## 4. Build

```sh
./configure --with_no_x
make all
```

Under a minute on a recent laptop. Use `make all`, not a bare `make`.

For the native graphics window (Dear ImGui on Direct3D 11), fetch ImGui once
and configure with graphics instead:

```sh
./tools/fetch-imgui.sh
./configure --experimental-graphics
make all
```

There is no X11 build on Windows.

## 5. Check it, and run it

```sh
tools/validate-cygwin.sh
```

It should end with `0 failed`. Then:

```sh
./poplog pop11                  # Pop-11
./poplog prolog                 # Prolog
./poplog clisp                  # Common Lisp
./poplog pml                    # Standard ML
./poplog pop11 examples/eliza.p
```

At the Pop-11 prompt, `ved somefile` opens the editor; leave Pop-11 with
`sysexit();` or Ctrl-D. `./poplog` is a small script that sets the environment
(`$usepop` and friends) and runs what you name; `pop11`, `prolog`, `clisp`
and `pml` are in `target/pop`.

## Optional libraries

Each is a small C shim built once, against a Cygwin package from step 2:

```sh
tools/build-popcrypto.sh        # LIB CRYPTO       (OpenSSL)
tools/build-poppcre.sh          # LIB PCRE         (pcre2)
tools/build-popcurl.sh          # LIB HTTP_CLIENT  (curl)
```

The pop11 skill for Claude Code (`.claude/skills/pop11`) works here too. To
check it, sessions, checkpoints and its curl and SQLite shims included:

```sh
.claude/skills/pop11/bin/selftest
```

## Things that are different on Windows

- **Use a Cygwin shell.** `basepop11.exe` can be started from PowerShell if
  `C:\cygwin64\bin` is on `PATH`, but the `./poplog` script, the build and
  the tests all expect Cygwin's `sh`. File names inside Poplog are POSIX
  ones: `/cygdrive/c/...`, not `C:\...`.
- **Keep other Unix tools off the front of `PATH`.** Git for Windows ships
  its own `perl`, `sh` and friends, built for a different runtime. If they
  come before Cygwin's, test runners misbehave (every suite of
  `tools/test-libs.sh` reports a failure). In a login Cygwin shell Cygwin's
  tools come first; if in doubt, `export PATH=/usr/local/bin:/usr/bin:$PATH`.
- **If Poplog exits silently**, set `POP_FAULT_TRACE=1` and run it again. It
  reports every hardware exception and every change to the heap limit on
  standard error. A Windows process that runs out of stack, or dies of a
  fault nobody handles, can exit with status 0 and no message, which is why
  the validation script checks output and never exit status alone.
- **Graphics need a desktop session**, not a GPU: without one Direct3D's
  software renderer is used, and `POP_GFX_RENDERER=warp` forces it.
- **Antivirus.** The build writes and immediately runs a lot of small
  executables and saved images; real-time scanning slows it down and has not
  otherwise interfered.
- **Sharing a build.** The executables depend on `cygwin1.dll`, and saved
  images are tied to the executable they were made with. To move a build to
  another machine, copy the tree and install Cygwin there.

## Rebuilding and updating

After pulling changes, `make all` again. After a change to the compiler
back-end or the assembly files, do a clean rebuild so that nothing stale is
reused:

```sh
rm -f stamp_popc stamp_srclib stamp_vedlib
make all
```

To replace the seed with one built from the current source:

```sh
make stamp_new_corepop
cp target/pop/new_corepop.exe target/pop/corepop.exe
rm -f stamp_popc stamp_srclib stamp_vedlib && make all
```
