# Porting Poplog to Android (AArch64, API 29+) — as an embeddable library

**Status: thought exercise.** Nothing here has been built or measured. It
is written to the same shape as the other porting documents so that it
can become a work plan without being rewritten, and so that the places
where it is *guessing* are visible.

Target: 64-bit ARM Android, recent devices only (API 29 / Android 10 and
up, 8 GB+ RAM class). No 32-bit, no x86 emulator support, no Android TV
or Wear.

---

## 0. Which axis is this? — "same ISA, same kernel, someone else's process"

`PORTING-POPLOG.md` Part 0 splits every port into an **ISA backend** track
and an **OS/platform** track. Android is the first target where *both* are
largely solved before we start, and the work is somewhere neither track
describes:

| Track | Status for Android |
|---|---|
| **ISA backend** — registers, both code generators, assembly runtime | **REUSE** — AArch64 is done and validated on RPi5 and Apple Silicon |
| **OS layer** — syscalls, ELF, signals, memory, external-call ABI | **MOSTLY REUSE** — Android is Linux/AArch64; bionic is not glibc but it is POSIX |
| **Process model** — who owns the process, the signals, the stacks, stdin/stdout, and when it may exit | **ALL NEW — this is the entire job** |

Every previous port asked *"can Poplog run on this machine?"* This one
asks *"can Poplog run as a **guest** inside a process it does not own?"*
Poplog's engine assumes it **is** the process: it installs handlers for
`SIGSEGV` and `SIGBUS`, grows a break, keeps its call stack on the C
stack, reads `stdin`, and terminates by calling `exit()`. Inside an
Android app every one of those assumptions belongs to somebody else —
usually to ART, the Android runtime.

So the honest framing is: **the port is easy, the embedding is hard.**
Phase 1 below (a `basepop11` that runs under `adb shell`) is a weekend.
Phases 2–5 are the actual project.

---

## 1. The reuse baseline

Android on arm64 is Linux on arm64. Concretely, that means we expect to
reuse without modification:

- `pop/src/arm64/*` — every code generator, the assembly runtime, the
  frame contract (`PORTING-ARM64-FRAME-CONTRACT.md`).
- The `LINUX` branches throughout `pop/src/*.p` and `unixdefs.ph`.
- `pop/lib` in its entirety — it is *source*, loaded at runtime by
  `uses`, and 94 KB of Z-machine proved this month that a library costs
  the engine nothing.

Two bright spots worth banking early:

- **Page size is already right.** `arm64/sysdefs.p` sets
  `VPAGE_OFFS = 16384`. Android devices have historically used 4 KB
  pages, and newer ones are moving to 16 KB. A 16 KB Poplog page is a
  whole number of kernel pages either way, so `mprotect` granularity is
  finer than Poplog assumes rather than coarser — which is the safe
  direction. *(Verify in Phase 1; the reverse would be fatal.)*
- **We have already written the awkward half of the memory layer.** The
  Darwin port could not use `sbrk`, so `c_core.c` grew an mmap-backed
  break emulation (`_pop_brk` / `_pop_sbrk`, reserve-then-`mprotect`).
  Android wants exactly that same thing for a different reason (§4), and
  the code exists.

What bionic will cost us is small and dull: no `sbrk` worth using, a
different `dl*` story, `getpwuid`/locale stubs, and some `#_IF DEF LINUX`
branches that will want an `ANDROID` sibling. Budget days, not weeks.

---

## 2. The three hard problems

### 2.1 Signals — Poplog and ART both want `SIGSEGV`

This is the one that decides whether the project is viable.

Poplog uses `SIGSEGV` as a *control-flow mechanism*, not just an error
path. `getstore.p` keeps a `PROT_NONE` "limit page" immediately above the
user stack (`LOCK_LIM_PAGE`), and `errors.p` turns a fault whose address
equals `_userhi` into `User_underflow` — that is how *"ste: STACK EMPTY"*
is produced. `c_core.c` installs the handler with `sigaction` and
`_pop_errsig_handler` decides what the fault meant.

ART uses `SIGSEGV` for its own purposes — implicit null checks among them
— and Android ships **`libsigchain`** precisely because two runtimes in
one process both want the signal. Anything registering a handler must
chain rather than replace.

The plan:

1. **Register through the chain, not around it.** Keep using `sigaction`;
   `libsigchain` interposes. Do not use `sigaction` via raw syscall.
2. **Claim only our own faults.** `_pop_errsig_handler` must decide
   *first* whether the faulting address lies inside Poplog's own reserve,
   and return "not mine" otherwise so the next handler runs. We already
   built exactly this discipline for Darwin's W^X fixup, which bounds
   every decision by `break_base`/`break_limit`.
3. **Reduce the dependency.** The `I_CHECK` work landed this month means
   stack *overflow* is now caught by an explicit `_userlim` comparison
   planted at backward jumps, not by a fault. Underflow still needs the
   guard page — but an Android build could plausibly run with explicit
   checks only and treat any SEGV as fatal, which is a much easier
   promise to keep inside someone else's process.

**Risk if this fails:** the app crashes in ways that look like ART bugs.
This is the first thing to prototype and the reason Phase 3 exists as its
own phase.

### 2.2 Fixed addresses vs ASLR

Saved images (`.psv`) embed absolute addresses, which is why the Darwin
port re-execs with ASLR disabled and claims a fixed base at
`0x8000000000` with `mach_vm_allocate(VM_FLAGS_FIXED)`.

On Android neither lever exists: an app cannot re-exec itself with
`ADDR_NO_RANDOMIZE`, and `personality()` is not reliably available under
the app seccomp filter.

But the Darwin experience shows the lever we actually need is *not*
"disable ASLR" — it is "**choose our own base and get it every time**".
That works on Android:

- Reserve the whole arena up front with
  `mmap(0x8000000000, SIZE, PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_FIXED_NOREPLACE)`
  and grow it with `mprotect`, exactly as `_pop_brk` already does on
  Darwin. `MAP_FIXED_NOREPLACE` fails cleanly instead of clobbering an
  existing mapping, which is the behaviour we want when sharing an
  address space.
- The app's own ASLR then does not matter: nothing we address is
  relative to the executable.
- Collision with ART's mappings at 512 GB is unlikely but must be
  *probed*, not assumed. If it collides, fall back to a kernel-chosen
  base and accept that images do not restore (below).

**Image strategy, in order of preference:** (a) fixed base works, ship
`.psv` as normal; (b) fixed base works only sometimes — refuse to restore
on mismatch, which the loader already does; (c) it never works — drop
saved images on Android and pay the startup cost of building state from
source. Poplog is fast enough that (c) is survivable; it is the
`pop11_checkpoint` story that would be lost, not correctness.

### 2.3 The process model

Poplog assumes it owns the process. Inside an app it must be a polite
guest:

| Poplog assumes | Android reality | Approach |
|---|---|---|
| `exit()` on `sysexit` | would kill the host app | intercept the exit path; `longjmp` back to the API boundary and report "engine stopped" |
| owns `stdin`/`stdout` | no console at all | `dlocal` the character streams — the same hook the MCP server, the LSP server and `zio_char` already use |
| runs on the main thread | JNI calls arrive on many threads | one dedicated engine thread with a large stack; requests queued to it |
| may `fork`/`exec` helpers | exec from app-writable storage is blocked (API 29+) | `sysobey`, `LIB SHELL`, `LIB HTTP_SERVER`'s spawn path are **unsupported**; document it |
| `dlopen`s arbitrary `.so` | only from the APK's lib dir | `exload` limited to libraries shipped in the APK; `popcurl`/`popsqlite` would need building into the APK |
| has a writable `$usepop` tree | assets are read-only | unpack `pop/lib` from APK assets to `filesDir` on first run |

The threading answer deserves emphasis because **we have already built
it twice**. `popsession` (a persistent engine behind a request/response
protocol with captured output and a mishap trap) and the MCP server
(the same thing over JSON-RPC) are precisely the shape an Android
embedding needs. The Android API is not a new design — it is
`popsession` with JNI instead of a FIFO.

---

## 3. Architecture

```
   Kotlin/Java  ──JNI──▶  libpoplogjni.so  ──▶  libpoplog.so
   (app UI)                (thin shim)          (the engine)
                                │
                                └── engine thread, big stack, request queue
```

**`libpoplog.so`** — the existing engine, linked as a shared object
instead of an executable. `poplink` already produces a linkable object;
the change is to stop emitting an entry point and instead export:

```c
int   poplog_init(const char *usepop_dir);   /* boot the engine, once */
char *poplog_eval(const char *code);         /* compile+run, return captured output */
int   poplog_alive(void);
void  poplog_shutdown(void);
```

`poplog_eval` is `skill_run` with a different transport: install the
mishap trap, `dlocal` the output streams into a buffer, compile the
string, return everything printed. The refusal-on-incomplete-input check
the MCP server needed (unterminated strings corrupt the shared itemiser)
applies here unchanged.

**`libpoplogjni.so`** — marshals Java strings, owns the engine thread,
and enforces "one call at a time". Kept separate so the engine has no
JNI dependency and can still be tested from `adb shell`.

**Why not JNI directly into the engine?** Because the engine must remain
runnable headless for the validation ladder, and because a crash in the
shim should be distinguishable from a crash in Poplog.

---

## 4. Runtime code generation

Poplog compiles to native code into its own heap, which on Android runs
into W^X policy. Two paths, tried in order:

1. **Plain `PROT_EXEC` anonymous memory.** SELinux grants `execmem` to
   the `untrusted_app` domain because ART's own JIT needs it. If this
   works, nothing else is required. *Verify per-device; do not assume.*
2. **The Darwin dual-mapping trick, ported.** Create the arena with
   `memfd_create`, map it **twice**: RW at the canonical base, RX at
   `base + VIEW_OFFSET`. Execution runs in the alias, writes go to the
   canonical mapping, and no page is ever both. This is precisely
   `pop_make_view()` in `c_core.c` with `mach_vm_remap` replaced by a
   second `mmap` of the same fd — and the signal-handler PC redirect it
   needs is already written.

That second path is the quiet payoff of the macOS work: the hardest part
of Android's JIT story was solved a year early for a different operating
system.

---

## 5. Phases

Each ends in something runnable, mirroring the Part 7 ladder.

### Phase 1 — cross-compile, run under `adb shell` *(days)*
NDK toolchain (`aarch64-linux-android29-clang`), an `ANDROID` branch
beside `LINUX` in `unixdefs.ph`/`sysdefs.p`, corepop seeded by
cross-compiling from the RPi5 or macOS host exactly as the Darwin port
was seeded. **Acceptance:** `basepop11` starts a REPL over `adb shell`
and evaluates `2 + 2`. Not an app yet — this proves the OS layer alone.

### Phase 2 — shared library *(days)*
Suppress the entry point, export the four functions above, remove the
`exit()` path. **Acceptance:** a C test harness `dlopen`s
`libpoplog.so`, evaluates, and returns without the process dying.

### Phase 3 — signals *(the risky one)*
Chain through `libsigchain`; bound every handler decision by the arena;
prove ART and Poplog coexist. **Acceptance:** an app that triggers a
Poplog stack underflow *and* an ART null-pointer exception, in either
order, with both reported correctly and neither crashing the other.

### Phase 4 — memory and images
Fixed-base reserve with `MAP_FIXED_NOREPLACE`; decide the image story
from what the device actually gives us. **Acceptance:** 200k-item stack
growth (the `pushn` repro that found `I_CHECK`) survives, and either
`.psv` restores or refuses cleanly.

### Phase 5 — JNI, threading, I/O
Engine thread, request queue, output capture. **Acceptance:** a text
field in an app evaluates Pop-11 and shows the result, mishaps included.

### Phase 6 — packaging
`pop/lib` unpacked from assets on first run; `$usepop` pointed at
`filesDir`; APK size measured and recorded in `docs/release-sizes.md`
like every other target.

### Phase 7 — the acceptance demo
**Play *The Poplog Cave* on a phone.** `zplay_start`/`zplay_turn` already
give a turn-at-a-time API over a suspended Pop-11 process, so the app is
a text view and an input box. This is a good final test precisely because
it is unglamorous and exercises everything: the compiler, the object
tree, coroutines (which need `_ussave`, fixed on arm64 only this month),
memory growth, and captured I/O.

**Out of scope:** VED, X, graphics, all four language images (Prolog,
Lisp, ML would follow for free but are not the point), 32-bit, and any
device older than API 29.

---

## 6. What Android can still break

Honest list, roughly by descending fear:

- **Signal coexistence** (§2.1). If `libsigchain` does not behave as
  documented under a given OEM's runtime, the whole embedding is
  unreliable and the answer becomes "run Poplog in a separate process
  and talk to it over a socket" — which works, and is much less
  interesting.
- **Background execution limits.** Android will freeze or kill an app's
  threads; a Poplog session is not guaranteed to survive backgrounding.
  Checkpointing to a `.psv` is the natural mitigation and depends on §2.2.
- **Play Store policy on dynamic code.** Poplog compiles *user-supplied
  source* to native code at runtime, which is what a JavaScript or Lua
  engine does — but the policy language about "downloading executable
  code" is written loosely enough to be worth a real answer before
  shipping. This is a policy question, not a technical one, and it should
  be settled early because it can invalidate the product without
  invalidating the port.
- **`memfd_create` availability** across the target API range if path 2
  of §4 is needed.
- **16 KB page devices** arriving mid-project and changing the alignment
  assumptions under us.
- **Vendor SELinux policy** that is stricter than AOSP's on `execmem`.

---

## 7. Rejected alternatives

- **Termux.** Poplog already builds there in effect (it is ordinary
  Linux/aarch64), but it is a terminal app for developers, not a way to
  embed Poplog in *someone else's* application. Useful as a Phase-1
  shortcut; not the goal.
- **Separate process + socket.** Sidesteps every signal and memory
  problem by giving Poplog its own process, and is the fallback if
  Phase 3 fails. Rejected as the primary design because it forfeits the
  thing that makes this interesting — being *in* the app, sharing its
  lifetime and its data.
- **WebAssembly.** A wasm backend is a separate, larger project
  (2030plan 1.4c). It would reach Android through a browser rather than
  as a native library, and would lose native code generation, which is
  Poplog's whole pitch.
- **Rewriting the engine as reentrant/thread-safe.** The single-threaded
  assumption is deep (one user stack, one break, one itemiser). The
  dedicated-thread design gets the same result for a fraction of the
  cost.

---

## 8. Why bother

The thought exercise is worth writing down because the answer is not
"because we can":

- **An incrementally-compiling, natively-compiled language living inside
  an app**, with a session that persists across interactions. That is a
  scripting layer with no interpreter tax.
- **On-device agent tooling.** The MCP server is already the shape of an
  agent runtime; on Android it becomes an *on-device* one, with no
  network round trip and no data leaving the phone.
- **The teaching corpus in a pocket.** 921 documentation pages and a
  Z-machine that plays real interactive fiction, in an app, offline.

And one strategic reason: this port would prove Poplog can be a **guest**
rather than a host. That capability is what makes every subsequent
embedding — an iOS app, a plugin, a game engine, a language server inside
someone else's editor — a variation on work already done rather than a
new port.

---

## 9. References

- `PORTING-POPLOG.md` — the general recipe; Part 0 (tracks), Part 4 (OS
  layer), Part 7 (validation ladder).
- `PORTING-ARM64-LINUX-RPI5.md` — the ISA baseline being reused.
- `PORTING-ARM64-M-SILICON-OSX.md` — the closest analogue: same ISA, new
  OS, and the source of the break emulation (§2.2) and the dual-mapping
  JIT design (§4).
- `PORTING-ARM64-FRAME-CONTRACT.md` — the invariant neither OS touches.
- `docs/bugs/userstack-growth-aslr.md` — why `I_CHECK` matters to §2.1.
- `pop/extern/lib/c_core.c` — `_pop_brk`, `pop_make_view`,
  `_pop_errsig_handler`: the three pieces of C this port would rework.
