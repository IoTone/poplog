*English | [日本語](README.ja.md)*

POPLOG is a free, open source, multi-language software development
environment providing incremental compilers for a number of interactive
programming languages, notably:

* Pop-11
    The core language of Poplog, including a rich interface to the X
    window system and a powerful Object Oriented programming extension,
    Objectclass, developed by Steve Leach now a standard part of the
    language (comparable to CLOS as an extension of LISP). 
* Prolog
    Standard prolog with the "Edinburgh" syntax.
* Common Lisp
    Compatible with most of CLTL2 (Common Lisp the language, 2nd
    Edition) by G.L. Steele
* Standard ML
    A powerful, strongly typed, polymorphic, functional language.

Poplog provides support for multi-paradigm software development in a
rapid prototyping environment, because of the use of (fast) incremental
compilers for all the languages.  There is substantial AI and teaching
material using Poplog, some included in this repository, some
in separate packages repository, some available on the net.

---

## The four languages, live

All four incremental compilers share one virtual machine and one saved image,
and interoperate freely.  Captured from the Apple Silicon (macOS) build:

| Pop-11 — the core language | Prolog — Edinburgh syntax |
| :---: | :---: |
| ![Pop-11 REPL](docs/images/repl-pop11.png) | ![Prolog REPL](docs/images/repl-prolog.png) |
| **Common Lisp — CLTL2** | **Standard ML — type inference** |
| ![Common Lisp REPL](docs/images/repl-clisp.png) | ![Standard ML REPL](docs/images/repl-pml.png) |

## Forth — a fifth language (new in this fork)

The four languages above are classic Poplog.  This fork adds a fifth,
**Forth**, as a first-class Poplog subsystem.  The design leans on Poplog's
open-stack calling convention so the implementation stays small and the result
is genuinely native:

* **Forth's data stack *is* the Poplog user stack**, so Forth primitives are
  ordinary open-stack Pop-11 procedures (`+` is `define f_plus(x,y); x+y
  enddefine`).
* **Colon definitions compile to machine code.**  `: name … ;` transpiles to a
  Pop-11 procedure and is run through Poplog's incremental compiler, so a Forth
  word is a real native procedure — not threaded/interpreted code.  Control
  words (`if/else/then`, `begin/until`, `begin/while/repeat`, `do/loop`,
  `recurse`, `exit`) map onto Pop-11 constructs at compile time.
* **A first-class subsystem:** `.fth` is a recognised file type and `uses
  forth;` enters the REPL, alongside `pop11`/`lisp`/`prolog`/`ml`; `bye` or
  `pop11` returns to Pop-11.

```
$ tools/forth.sh                 # interactive REPL  (-t testbench, -b bench, -c '…')
forth> : sq  dup * ;
forth> 9 sq .
81  ok
forth> : fib  dup 2 < if drop 1 else dup 1 - recurse swap 2 - recurse + then ;
forth> 10 fib .
89  ok
```

The current core covers arithmetic, ~40 stack/compare/bitwise/IO words, native
colon definitions, the control words above, counted loops (`do/loop/i/j/leave`),
`variable`/`constant`/`@`/`!`, a return stack (`>r r@ r>`), and string literals.
It is newer and leaner than the four mature languages (no `+loop` /
`create does>` / `value` yet; case-sensitive).  Because it is pure Pop-11 it
runs on **every platform Poplog does**; the built-in `testbench` is **21/21** on
macOS arm64 and on RISC-V (StarFive VisionFive).  Implementation:
`pop/forth/src/forth.p`; examples in `pop/forth/examples/`; performance in
[BENCHMARKS.md](BENCHMARKS.md#forth).

## Platforms

Poplog builds and runs natively on a growing set of platforms
(status as of June 2026):

| OS | Architecture | Status | Notes |
| --- | --- | --- | --- |
| **Linux** | x86-64 | ✅ Supported | Reference platform |
| **Linux** | AArch64 (ARM64) | ✅ Supported | Validated + benchmarked on **Raspberry Pi 5** and **MediaTek Genio 720** (MT8391, 2×A78+6×A55; GlobalScale Cortadodeck 720) — all four languages + saved images.  Generic `armv8-a`, no core-specific tuning, so other ARM64 boards (Qualcomm Snapdragon etc.) should follow readily |
| **macOS** | Apple Silicon (arm64) | ✅ Supported | Native Mach-O port — self-hosting, all four languages, terminal VED, C↔Pop callbacks, and native graphics |
| **Linux** | ARM32 (`armv6`/`armv7`) | ✅ Supported | Long-standing 32-bit ARM port (`pop/src/syscomp/arm`); Raspberry Pi 1–3 and other 32-bit ARM Linux.  Not benchmarked in this report |
| **Solaris** | x86 (i386) | ✅ Supported | Upstream port (W. Hebisch); tested on Solaris 10 (`CC=gcc`, vendored `corepop_solaris.i386`).  Not benchmarked here |
| **FreeBSD** | x86-64 | ✅ Supported | Upstream port (W. Hebisch); tested on x86-64.  Not benchmarked here |
| **Linux** | RISC-V (`riscv64`, RV64GC) | ✅ Supported | Native RV64GC/LP64D port, self-hosting on a **StarFive VisionFive** (dual SiFive U74) — all four languages, saved images, terminal VED, and the FFI float ABI.  `tools/validate-riscv64.sh` = 14/14; also bootstrapped from the released seed corepop on a cloud RV64 host (Ubuntu 24.04), where the `lib json`/`lib crypto` suites pass.  See `PORTING-RISCV64-LINUX.md` |
| **Windows** | x86-64 | 🚧 TODO | Not yet ported (WSL2 runs the Linux build as an interim) |

"Supported" means it builds and runs.  The first three rows plus RISC-V are
validated *and* benchmarked in this fork; ARM32, Solaris/x86 and FreeBSD/x86-64
are existing Poplog ports (ARM32 long-standing; Solaris + FreeBSD recent upstream
additions by W. Hebisch) that simply haven't been re-tested or benchmarked here.
The one remaining 🚧 row (Windows) is genuinely not yet ported.  See the
[platform-coverage table in BENCHMARKS.md](BENCHMARKS.md#platform-coverage).

Per-platform porting notes: `PORTING-ARM64-LINUX-RPI5.md` and
`PORTING-ARM64-M-SILICON-OSX.md`.

## Install

Three ways in, fastest first:

**1. Binary one-liner (~2 MB download; also installs the
[pop11 Claude skill](.claude/skills/pop11/SKILL.md)):**

```sh
curl -fsSL https://raw.githubusercontent.com/IoTone/poplog/master/tools/install-skill.sh | sh
```

Detects your platform, pulls `pop11-skill-<os>-<arch>.tar.gz` from the
latest GitHub release (macOS arm64 and Linux x86-64 to start), unpacks a
relocatable runtime (`basepop11` + libraries) to `~/.local/share/pop11-skill`,
and finishes with a live smoke test.  `POP11_SKILL_PREFIX` overrides the
location; `POP11_SKILL_URL` pins a version (any curl-able URL, including
`file://`).  Uninstall:
`rm -rf ~/.local/share/pop11-skill ~/.claude/skills/pop11 ~/.cache/pop11-skill`.
Tarballs are built by `tools/release-skill-tarball.sh` and published with
checksums (`SHA256SUMS.pop11-skill`) on the releases page.

Releasing is one tag: pushing `skill-YYYY.MM` runs
[`.github/workflows/skill-release.yml`](.github/workflows/skill-release.yml),
which builds x86-64 Linux, AArch64 Linux and Apple Silicon macOS from the
seed vendored in that commit, runs the library suites and the fork-hang
regression on each, installs every tarball through `install-skill.sh` into a
path unrelated to its build directory, and publishes with checksums. Run it
from the Actions tab first to build and verify without publishing anything.
**RISC-V has no hosted runner**, so `pop11-skill-linux-riscv64.tar.gz` is
still hand-built on `machine1` and uploaded to the same tag; re-running the
workflow afterwards folds it into `SHA256SUMS.pop11-skill`, which the
publish step reads off the release rather than assuming three platforms.

**2. From source** — see [INSTALL](INSTALL): seed `target/pop/corepop`
(binaries vendored under `nix/seeds/` for the four ported platforms),
then `./configure && make all`.

**3. Nix** — see the next section.

## Agents: the MCP server

Poplog ships an [MCP](https://modelcontextprotocol.io) server — written
in Pop-11 itself (`pop/mcp/pop11_mcp.p`) — so any MCP-capable agent gets
a **persistent, natively-compiled Pop-11 session** with four tools:
`pop11_eval` (state and compiled procedures survive between calls;
mishaps come back as diagnostics and the session survives),
`pop11_help` (the real HELP/REF/TEACH corpus), `pop11_checkpoint`
(freeze the whole session to a ~200 KB image, optionally gated on a
verify expression) and `pop11_state`.  Measured: 100+ eval round trips
in 0.04 s wall including engine startup.

Register it with Claude Code (the tarball install ships the launcher
too, at `~/.local/share/pop11-skill/tools/pop11-mcp`):

```sh
# every project on this machine:
claude mcp add --scope user pop11 -- /path/to/poplog/tools/pop11-mcp

# or one project (writes a committable .mcp.json):
claude mcp add --scope project pop11 -- /path/to/poplog/tools/pop11-mcp
```

This checkout's own [.mcp.json](.mcp.json) registers it for sessions
started here.  Resume a checkpointed session with
`pop11-mcp --restore image.psv`.  Scope semantics and the `.mcp.json`
format are documented in the
[Claude Code MCP docs](https://docs.claude.com/en/docs/claude-code/mcp);
other MCP clients configure the same stdio command their own way.
End-to-end protocol tests: `python3 tools/mcp/test-e2e.py`.

## Editors: the LSP server

The same idea for editors: a Language Server Protocol server written in
Pop-11 (`pop/lsp/pop11_lsp.p`, launched by `tools/pop11-lsp`, also
shipped in the tarball). Because the server *is* a Poplog session,
diagnostics come from the **real compiler** — buffers are checked with
`pop_syntax_only` set, so the VM plants nothing and nothing in your file
executes — hover shows the actual HELP/REF/TEACH entry for the word
under the cursor, and completion draws from the live dictionary. The
[Neovim plugin](editors/nvim/) starts it automatically for `pop11`
buffers; any LSP client can run the same stdio command. End-to-end
protocol tests: `python3 tools/lsp/test-e2e.py`.

Both servers sit on one transport, `pop/lib/lib/jsonrpc.p` — line and
Content-Length framing, stdio and TCP endpoints, and a serve loop that
turns a handler mishap into a `-32603` and keeps going. Factoring it out
took 342 lines out of the two servers, and it is what the swank server
below is built on.

## Editors: the live session

`pop/lib/lib/swank.p` is the other half of the idea, named after SLIME's
swank for the same reason: the interesting thing an editor can talk to
is not a compiler but a **running session**. The LSP server answers
questions about text; this answers questions about a live heap — what a
name is bound to *now*, what a procedure printed *while it ran*, which
frames were on the stack when it died.

Output streams back as it is produced rather than arriving in one lump
at the end, mishaps come back as data (`message`, `culprits`, `frames`)
rather than as a block of text to scrape, and a runaway loop is stopped
by signalling the pid the handshake hands you — which works because
`I_CHECK` was implemented on arm64 and riscv64 earlier in this arc.

Start one from a session you are already using, and the editor gets that
session, with everything in it:

```pop11
uses swank;
swank_serve(4005);          ;;; SLIME's port, since it is the same idea
```

or `tools/pop11-swank` to start a fresh one. Tests:
`sh tools/test-libs.sh tools/tests/test_swank.p` — 56 checks against a
real server in a second process, including the interrupt.

The [Emacs package](editors/emacs/) is the client: `M-x pop11-swank`
starts a session and connects, and from then on the editing commands go
there. Output streams into the REPL as the code runs, a mishap opens a
backtrace buffer with real frames, `C-c C-i` inspects a value and drills
into its parts by handle, `M-.` asks the running heap where a name came
from, completion reads the live dictionary, and `C-c C-a` stops a
runaway loop.

`TEACH SWANK` is the walkthrough: connecting by hand, watching output
stream, taking a mishap apart, interrupting a runaway loop, inspecting a
live value -- before any editor is involved.

The [Emacs package](editors/emacs/) goes further and reaches for the
other half of the idea: `M-x run-pop11` puts a real Poplog listener in a
comint buffer, and the editing buffer gets VED's `ENTER` commands on
Emacs keys — `C-x C-e` for `ENTER l1`, `C-c C-r` for `ENTER lmr`,
`C-M-x` for `ENTER lcp` — so a procedure goes from buffer to running
image without leaving the file. Tests:
`emacs -Q --batch -l tools/emacs/test-e2e.el`.

## Packaging (Nix)

A self-contained **Nix flake** builds and bootstraps the whole system — all
four languages and their saved images — from source, with no manual seed or
toolchain setup.  Tested end-to-end on `x86_64-linux` and `aarch64-darwin`;
the `aarch64-linux` build is deployed and benchmarked on a MediaTek Genio 720
(the **G720** column in BENCHMARKS.md is the flake build running from a Nix
profile).

```sh
nix build .#poplog          # build; then ./result/bin/{pop11,clisp,prolog,pml,ved}
nix run   .#pop11           # run a REPL directly (or .#prolog / .#clisp / .#pml)
nix shell .#poplog          # drop all five front-ends onto $PATH
nix develop                 # dev shell for hacking on Poplog sources
nix build .#poplog-gfx      # experimental graphics: Metal on macOS, SDL3+OpenGL3 on Linux
```

The flake exposes `packages`, `apps`, and a `devShell` for every supported
system.  On macOS the build is signed ad-hoc with **no entitlements required**.

**First-build cost:** Nix builds the whole toolchain closure from source, so
the first build pulls **~1.1 GB** of cached dependencies and lands a **~1.2 GiB**
on-disk closure (the Poplog out-path is ~95 MB; the rest is shared deps), taking
a couple of minutes to build.  Subsequent builds of the same source fetch
nothing.  Full details — use cases, costs, the bootstrap-seed story, and the
graphics variant — are in **[`nix/README.md`](nix/README.md)**.

## Native graphics (experimental)

Historically Poplog's graphics were tied to the X window system (Xpw / `xved`).
There is now an **optional native graphics backend** built on
[Dear ImGui](https://github.com/ocornut/imgui), selected at build time with
`./configure --experimental-graphics` (it implies "no X"):

* **Metal + Cocoa** (macOS) — a native window with no X server or XQuartz.
* **SDL3 + OpenGL3** (macOS *or* Linux/Unix) — SDL3 selects the display
  transport at run time — **Wayland**, X11, or KMS/DRM — so there is **no hard
  X11 dependency**; it also renders **headless** via Mesa software (llvmpipe)
  for CI.

The **backend is chosen at build time**, so you can pick one and explore:

```sh
./configure --experimental-graphics          # per-OS default: Metal on macOS, SDL elsewhere
./configure --experimental-graphics=metal     # force Metal  (macOS only)
./configure --experimental-graphics=sdl       # force SDL3 + OpenGL (macOS or Linux)
```

`=sdl` needs SDL3 (`pkg-config sdl3` — e.g. `brew install sdl3`; or point at a
build with `SDL3_CFLAGS=… SDL3_LIBS=… ./configure --experimental-graphics=sdl`).
The running backend (and GPU) is reported by `gfx_spec()`; see the badge below.

The macOS **Metal** backend, live — `examples/cube3d.p`, a smooth vsync-paced
spin with an on-screen stats badge (backend, GPU, live FPS):

![Spinning 3D cube on the macOS Metal backend](docs/images/cube3d-metal.gif)

The classic `rc_graphic` turtle library and `rc_mouse` are ported onto it, so
existing Pop-11 graphics code runs unchanged.  Graphics are strictly **opt-in**:
the default build (and `nix build .#poplog`) is console-only.

| `rc_graphic` turtle on macOS (Metal) | Headless render on Linux (SDL3 + llvmpipe, no display) |
| :---: | :---: |
| ![macOS native graphics](docs/images/graphics-macos.png) | ![Linux headless graphics](docs/images/graphics-linux-headless.png) |

The right-hand image was rendered on Linux with **no display, GPU, or
compositor** (`tools/validate-gfx-headless.sh`) — the reproducible CI gate for
the graphics stack.

A few runnable demos live in [`examples/`](examples/) (`pop11
examples/tenprint.p` on a graphics build) — for instance the classic
[10 PRINT](https://10print.org/) maze and "POPLOG" drawn out of small letters:

| `examples/tenprint.p` | `examples/poplog_letters.p` |
| :---: | :---: |
| ![10 PRINT maze](docs/images/ex-tenprint.png) | ![POPLOG in letters](docs/images/ex-poplog-letters.png) |

## Performance

Poplog's incremental compilers emit fast native code on every backend.  For
cross-platform and cross-language benchmark numbers (x86-64, Apple M-series,
Raspberry Pi 5, MediaTek Genio 720, RISC-V, with Python and Perl baselines for
context), see **[BENCHMARKS.md](BENCHMARKS.md)**.

## Documentation

The full in-tree corpus — 900+ HELP, TEACH and REF files — is browsable
at **<https://iotone.github.io/poplog/>** (with
[`llms.txt`](https://iotone.github.io/poplog/llms.txt) for AI
assistants).  The site is regenerated on every push by
`tools/gen-docs.sh`, a Pop-11 program: Poplog builds its own docs site
in CI, from a released seed corepop, in under a second of generator
time.  Inside the system the same material is available as `help json`,
`teach json`, `ref regexp` etc. in ved.

## Learning material

Decades of open Pop-11/Prolog teaching material — the Birmingham AI course
TEACH files, the SimAgent toolkit, the Pop-11 Primer, and more — are one
command away:

```sh
tools/fetch-learning.sh --all       # fetch into learn/ (gitignored)
```

The material is downloaded from public archives, never vendored here; a
generated `learn/learn.p` wires it into `teach`/`help` inside Poplog.  See
**[LEARNING.md](LEARNING.md)** for the pack list and usage.

---

This is a cleaned-up version of the Poplog sources, the core part only: it
carries neither the bootstrap binaries nor the extension packages. Both live
elsewhere, along with the rest of this repository's ancestry — see
**[Where this came from](#where-this-came-from)** below.

Bootstrap (`corepop`) binaries for the platforms ported here — x86-64 Linux,
AArch64 Linux, Apple Silicon macOS, and RISC-V RV64GC Linux — are published
with checksums on [this repository's
releases](https://github.com/IoTone/poplog/releases) (e.g.
`releases/download/corepops-2026.10/corepop-aarch64-linux`). Seed URLs name
their `corepops` tag rather than `latest`, which the skill releases own; the
same seeds are vendored under `nix/seeds/` for the Nix flake build.

The **AArch64 Linux** port (see the Platforms table above) is written to the
generic `armv8-a` baseline and flushes the instruction cache via
`__clear_cache`, so it ports readily to other ARM64 boards -- the main
platform-specific knob is the kernel **page size** (saved images are
page-aligned; the Pi 5 uses 16 KB pages).  See `PORTING-ARM64-LINUX-RPI5.md`
(and its "Portability to other AArch64 platforms" section) for details.

For more detailed installation instructions see INSTALL.

---

## Where this came from

Poplog is over forty years old and this repository is the latest link in
a chain. GitHub shows no "forked from" banner on it, because the history
arrived by push from an account that no longer holds it rather than through
the fork button — so the lineage is recorded here instead.

### This repository's direct ancestor

**[hebisch/poplog](https://github.com/hebisch/poplog)** — Waldek Hebisch's
cleaned-up Poplog, and the repository this one continues. The relationship
is not a resemblance; it is the same history. This repository's root commit
`d8f2a1c` ("Inital commit", 19 Feb 2019) is Hebisch's, it is present in his
repository too, and the two share every commit up to `6bbfa28` (18 May
2023). Everything after that is this fork. Hebisch's repository is still
maintained and is the place to look for changes that have not been brought
across; the opening description of Poplog at the top of this README is his
wording, kept deliberately.

Also his, and still the right sources for things not built here:

* **[hebisch/poplog_packages](https://github.com/hebisch/poplog_packages)** —
  the extension packages, which this repository does not vendor.
* **<http://poplog.fricas.org/>** — the Free Poplog site: documentation, and
  at **<http://poplog.fricas.org/bham/>** a file-level **copy of the
  Birmingham site**. Worth knowing about before you need it: `poplog.org`
  has already been lost (see below), so a second copy of the Birmingham
  material is not redundancy for its own sake.
* **<https://poplog.fricas.org/corepops>** — bootstrap `corepop` binaries for
  the older upstream platforms (the four platforms ported *here* are on
  [this repository's releases](https://github.com/IoTone/poplog/releases),
  and vendored under `nix/seeds/`).
* **<http://fricas.org/~hebisch/poplog>** — a buildable tarball for
  Intel/AMD 64-bit Linux.

### Before GitHub

Poplog was built at the **University of Sussex**, carrying forward the POP
language line — the HELP files still document compatibility with "older
dialects of POP (such as POP-2, POP-10, WPOP)". The sources here keep their
notices: `Copyright (c) 1982-1999 University of Sussex. All rights
reserved.`, and *Poplog* is a registered trade mark of the University of
Sussex.

You do not have to take that history second-hand; it is signed throughout
the tree, and these are the names you meet most often reading it. **John
Gibson** appears in over 1,600 files, most of the compiler and virtual
machine sources among them. **Robert Duncan** signs around 300, including
much of the HELP corpus. **Aaron Sloman** is on documentation from 1982
onwards and later curated the free release. **Chris Mellish** wrote the Prolog
documentation (1983), **Steve Hardy** help files from as early as 1978, and
**Steve Leach** the Objectclass extension described at the top of this
README.

Poplog was then sold commercially under licence by **Integral Solutions
Limited** (ISL) of Bristol. The licence agreement between Sussex and ISL
survives in the tree as `HELP POPLOG_LICENCE` — as a record only: Poplog was
released for free use in the late 1990s, and ISL's site (`www.isl.co.uk`) no
longer resolves.

The free release has been curated since at the **University of Birmingham**
by Aaron Sloman, and those pages are still up and still the best account of
what Poplog is and why:

* **<https://www.cs.bham.ac.uk/research/projects/poplog/freepoplog.html>** —
  Free Poplog.
* **<https://www.cs.bham.ac.uk/research/projects/poplog/poplog.info.html>** —
  background and papers.
* **<https://www.cs.bham.ac.uk/~axs/>** — Sloman's own pages, including much
  of the thinking Poplog was built to serve.

Decades of the teaching material that went with it — the Birmingham AI
course TEACH files, the SimAgent toolkit, the Pop-11 Primer — are fetched on
demand by `tools/fetch-learning.sh`; see [LEARNING.md](LEARNING.md).

### Is there a Poplog foundation? Where do people talk?

There is no foundation, no governing body and no trademark steward in
practice — the trade mark rests with the University of Sussex, and
maintenance is Hebisch's repository, this one, and the archives above. The
**BCS Poplog and Pop Languages User Group** (PLUG) ran conferences and a
newsletter into the 1990s and has been dormant since; `HELP PLUG` keeps its
details "in case users decide to revive PLUG", and the `comp.lang.pop`
newsgroup named throughout the HELP files is likewise historical.

There is, however, somewhere to ask a question:

* **pop-forum@gaggle.email** — "a mailing list for Poplog and Pop-11", the
  closest thing to a current community venue. Subscribe at
  **<https://gaggle.email/join/pop-forum@gaggle.email>**. (Use the join
  link; `gaggle.email/g/pop-forum` is a members' sign-in page and shows
  nothing to a visitor.)

> **A warning about `poplog.org`.** Several in-tree HELP files, written in
> 1999, point readers at `http://www.poplog.org`. That domain is no longer
> connected to Poplog: it now serves unrelated search-engine filler. The
> HELP files are left as the historical record they claim to be, but do not
> follow that link, and do not treat it as an upstream source.

### Licensing, honestly

This repository has no `LICENSE` file, and neither does
[hebisch/poplog](https://github.com/hebisch/poplog) (GitHub reports no
declared licence for it). What the tree actually contains is the University
of Sussex copyright notices above, plus `HELP POPLOG_LICENCE`'s statement
that "Poplog licence terms & conditions are no longer relevant as Poplog is
freely available" and that the free versions are supplied "as is", at the
user's sole risk, with no warranty of any kind. That is the basis on which
the code has been redistributed for twenty-five years, and this README
describes it rather than restating it as a licence grant, which is not ours
to make. If you need formal terms for your own use, the Birmingham pages
above are the right starting point.
