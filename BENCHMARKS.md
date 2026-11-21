# Poplog engine micro-benchmarks

**Revision 2026-07 (rigorous re-collection; Apple M5 Pro and RISC-V StarFive VisionFive added 2026-06; MediaTek Genio 720 added 2026-07).** Micro-benchmarks of Poplog's runtime-core
mechanics — procedure calls, integer arithmetic, allocation/GC, incremental
compilation, closures, and string handling — with Python and Perl baselines on
the same workloads. These characterise the *engine*, not applications, and are
deliberately small and single-threaded.

> **Collected with the rigorous harness (`tools/bench.sh`).** Every number
> below is the **median of 30 runs**, CPU-time, auto-calibrated batches, with a
> **bootstrap 95 % CI** and coefficient of variation. All six machines ran the
> *same* Poplog (version 160200) on the *same* workloads. See
> [Methodology](#methodology). Reported per-iteration times are in **ms / µs,
> lower is better**; cross-language cells are **slowdown ratios vs Poplog**
> (>1 = slower than Poplog).
>
> **Scope.** These characterise the *engine*, not applications, and are
> deliberately small and single-threaded. Every protocol detail, unit, and
> cross-language asymmetry is disclosed so the numbers read (and reproduce)
> correctly. See [Threats to validity](#threats-to-validity).

---

## Systems under test

| ID | CPU | Cores / clock | RAM / cache | OS, governor | Poplog build (verified) |
|---|---|---|---|---|---|
| **i7** | Intel Core i7-9700K (Coffee Lake, 2018) | 8C/8T, 3.6–4.9 GHz | 31.3 GiB; L2 2 MiB, **L3 12 MiB** | Ubuntu 22.04 LTS, x86-64; `powersave` (intel_pstate, boosts under load) | Nix flake, `ELF 64-bit … x86-64` |
| **M2** | Apple M2 (2022) | 8-core (4P+4E), ~3.5 GHz | 16 GiB; L1d 64 KiB, L2 4 MiB | macOS, arm64; no governor (P/E auto-sched) | This port, native `Mach-O … arm64` |
| **Pi5** | Broadcom BCM2712 (Cortex-A76, 2023) | 4C, 2.4 GHz | 7.9 GiB; L2 2 MiB, L3 2 MiB | DietPi (Debian), arm64; `performance` | Native `ELF … arm64`, generic `armv8-a` |
| **G720** | MediaTek Genio 720 / MT8391 (GlobalScale Cortadodeck 720, 2025) | 8C big.LITTLE: 2× Cortex-A78 @ 2.6 GHz + 6× Cortex-A55 @ 2.0 GHz | 7.6 GiB; caches not exposed by the vendor kernel | Linux 6.6 (vendor MTK kernel), aarch64; `performance` | Nix flake (`aarch64-linux`), `ELF … ARM aarch64`, generic `armv8-a` |
| **M5** | Apple M5 Pro (2025) | 18-core (6P+12E); clock not exposed by macOS | 48 GiB; L1d 64 KiB, L2 8 MiB | macOS 26.4, arm64; no governor (P/E auto-sched) | This port, native `Mach-O … arm64` |
| **VF** | StarFive JH7100 (dual SiFive U74, 2021) | 2C, ~1.0 GHz, **in-order** | 7.0 GiB; L1d 32 KiB, L2 2 MiB | Ubuntu 24.04, riscv64 (kernel 6.5-starfive); no cpufreq governor | This port, native `ELF … RISC-V`, RV64GC |

All six ran Poplog **version 160200**. Each engine's architecture was
`file`-verified before benchmarking — on the i7 this caught a stray *aarch64*
`basepop11` that would have run under qemu (the failure mode in
[Threats to validity](#threats-to-validity)); the nix x86-64 build was used
instead. The **VF** binary was likewise confirmed `ELF … UCB RISC-V` running
*native* on the board (not the x86-64 host under qemu-user). Interpreter baselines: CPython **3.10.12** (distro) and **3.13.0rc2**
(uv, PGO/LTO standalone) on i7; **3.14.0** on M2 and M5; **3.13.5** on Pi5;
**3.12.13** on G720; Perl **5.34** (i7/M2/M5), **5.40** (Pi5) and **5.42**
(G720) — interpreter *build* matters as much as
version (see [Analysis](#analysis)), so each is named.

The environment is not pinned (no CPU isolation, fixed governor, or thermal
control); results are intended for **within-machine, cross-engine** comparison,
not cross-machine ranking.

### Platform coverage

The six machines above are what this report measures. For completeness, the
full set of platforms Poplog targets (or has historically targeted) — including
the ones not yet ported or benchmarked in this fork — is:

| Platform | Architecture | Port status | Benchmarked here |
|---|---|---|---|
| Linux | x86-64 | ✅ Supported (reference) | ✅ i7 |
| macOS | Apple Silicon (arm64) | ✅ Supported (this port) | ✅ M2, M5 |
| Linux | AArch64 / `armv8-a` | ✅ Supported (RPi 5, MTK Genio 720) | ✅ Pi 5, G720 |
| Linux | ARM32 (`armv6`/`armv7`, RPi 1–3) | ✅ Supported (long-standing) | — not benchmarked |
| Solaris | x86 (i386) | ✅ Supported (upstream; Solaris 10) | — not benchmarked |
| FreeBSD | x86-64 | ✅ Supported (upstream) | — not benchmarked |
| Linux | RISC-V (`riscv64`, RV64GC) | ✅ Supported (this port; StarFive VisionFive) | ✅ VF |
| Windows | x86-64 | 🚧 Experimental (Cygwin port, branch `windows-checkout`; see `PORTING-X86-64-WINDOWS.md`) | ✅ W11, in [its own section](#windows-11-experimental-port) |

There are two tiers below the six benchmarked machines. **Supported but not
benchmarked here:** ARM32 Linux, Solaris/x86 and FreeBSD/x86-64 are real,
building Poplog ports (the 32-bit ARM backend `syscomp/arm` is long-standing;
Solaris/i386 and FreeBSD/x86-64 are recent upstream additions by W. Hebisch,
tested on Solaris 10 and x86-64 FreeBSD) — we simply have not run this harness
on them, so their benchmark column is *not benchmarked* rather than a number.
**Newly ported and benchmarked:** RISC-V (RV64GC) is now a native port — all four
languages self-host on a StarFive VisionFive and it is measured here as **VF**
(see `PORTING-RISCV64-LINUX.md`). **Not yet ported:** x86-64 Windows alone reads
*TODO* throughout (WSL2 runs the Linux build as an interim).

---

## Methodology

The harness (`tools/bench.sh`, driving `bench-poplog.p` / `bench-baseline.py` /
`bench-baseline.pl`, aggregated by `bench-aggregate.py`) follows a deliberately
conservative microbenchmark protocol:

* **Metric: CPU time, identical across engines.** Poplog `systime()`, Python
  `time.process_time()`, Perl `(times())[0,1]` — all **process CPU time
  (user+system)**. Using CPU time (not wall clock) makes the three engines
  *directly comparable* AND robust to background load, which matters most when
  "clearing the decks." (Poplog's wall-clock `sys_microtime` is unreliable on
  the Darwin port — it returns stale values inside compute-heavy procedures —
  so CPU time is also the *reliable* choice.)
* **Auto-calibration.** Each workload is repeated **K** times per timed batch,
  K chosen automatically so a batch lasts ≥ `BENCH_MINTIME` (default **2 s**) of
  CPU time. The per-iteration cost is the batch time ÷ K. This keeps the 10 ms
  timer resolution a tiny fraction of each batch on every engine, fast or slow.
* **Warm-up + repetition.** `BENCH_WARMUP` batches (default 3) are discarded to
  settle caches/allocation, then **`BENCH_RUNS` batches (default 30)** are
  recorded per workload.
* **Statistics.** The aggregator reports, per workload, **min, median, mean,
  coefficient of variation (CoV %), and a bootstrap 95 % CI on the median**
  (10 000 resamples). Cross-engine comparison reports the **ratio of medians
  with a bootstrap 95 % CI** — *a CI that excludes 1.0 is significant at ≈5 %*.
  Medians (not means) are headline because timing distributions are
  right-skewed by OS interference; pure-stdlib so it runs even on a Pi.
* **System-under-test capture.** `bench.sh` records CPU, logical cores, RAM,
  cache sizes, governor (and warns if it isn't `performance`), load average
  (warns if busy), and `file` of the engine (the binfmt/arch guard from
  [Threats to validity](#threats-to-validity)).
* **Identical workloads** across all three engines; cross-language mapping
  caveats are in [Workloads](#workloads).

---

## Workloads

| Key | What it does | Stresses | Cross-language note |
|---|---|---|---|
| **nfib29** | Naive doubly-recursive `nfib(29)` (≈1.35M calls) | Procedure-call overhead | Identical recursion in all three |
| **intloop10M** | Sum `1..10,000,000` in a tight loop | Integer arithmetic + loop dispatch | Boxed integers in both Pop and Python; on 32-bit Pop the sum overflows into **bignums** (see †) |
| **lists** | 200× build a 5,000-cell list + traverse (≈1M cons cells) | Allocation + GC pressure | Pop `conspair` ↔ chained 2-tuples; both traverse and discard |
| **compile500** | 500× **runtime-compile** a small procedure | Incremental compiler | **Pop compiles to *machine code*; Python `compile()` builds *bytecode*** — Pop does strictly more work, so parity is a *strong* result for Pop |
| **gc20** | 20× force a full GC over a heap of 50,000 live pairs | Garbage collector | Pop has a real moving GC; CPython is refcount + cycle collector — `gc.collect()` is the closest analogue |
| **closures1M** | 100k closures created, each called 10× (1M calls) | Closure creation + invocation | Equivalent closure capture in each |
| **strings** | Double a string 14× (→16 KB) then 200 substring searches | String build + search | Equivalent build-and-search |

† **32-bit overflow.** Pop-11 immediate integers ("popints") are ~29 bits, so
`intloop10M` overflows into bignums on 32-bit builds — that row then partly
measures bignum arithmetic. This is a real cost of 32-bit Poplog, *not* an
emulation artifact.

---

## Poplog across machines and backends

Poplog's own per-iteration time on each native machine — **median of 30 runs,
lower is better.** Coefficient of variation was **< 1 %** on every row except
the two M2 rows marked ◊ (see below) and M5 `nfib29` (1.3 %); the M5 run was
clean throughout (no E-core scheduling spikes this time).

| Workload | i7 (x86-64) | M2 (arm64) | Pi 5 (arm64) | G720 (arm64) | M5 Pro (arm64) | VF (riscv64) |
|---|---|---|---|---|---|---|
| nfib29 (calls) | 14.5 ms | 13.2 ms | 24.9 ms | 16.4 ms | **8.83 ms** | 230 ms |
| intloop10M | 61.5 ms | 52.2 ms | 124 ms | 80.4 ms | **42.4 ms** | 950 ms |
| lists (alloc/GC) | 11.4 ms | 9.0 ms | 22.2 ms | 15.2 ms | **7.54 ms** | 308 ms |
| closures1M | 22.0 ms | 45.1 ms ◊ | 33.5 ms | 28.6 ms | **27.3 ms** | 352 ms |
| gc20 | 20.4 ms | 28.4 ms ◊ | 48.1 ms | 32.2 ms | **12.0 ms** | 1.39 s |
| strings | 2.15 ms | 1.94 ms | 4.12 ms | 2.54 ms | **0.767 ms** | 10.4 ms |
| compile500 (→ machine code) | **66.7 ms ‡** | 9.0 ms | 13.5 ms | 16.9 ms ¶ | **5.52 ms** | 200 ms |

The M5 Pro is the fastest machine on every workload — vs the M2 (same port,
prior Mac) roughly **1.2–1.5×** on the call/loop/alloc/compile rows and **~2×**
on the cache- and GC-bound rows (`gc20`, `strings`; the M2's `closures1M`/`gc20`
medians are E-core-inflated ◊, so against the M2 *min*s the closures/gc gap is
~1.4–2.2×). Three Apple-Silicon generations (M2 2022 → M5 2025) of uplift on the
same native arm64 build.

**G720 (MediaTek Genio 720 / MT8391) — the second Linux/AArch64 machine, same
build recipe as the Pi 5 (generic `armv8-a`).** It lands almost uniformly
**~1.5× the Pi 5** (nfib 1.52×, intloop 1.54×, lists 1.46×, gc20 1.49×, strings
1.62×) — consistent with its out-of-order Cortex-A78 @ 2.6 GHz vs the Pi 5's
A76 @ 2.4 GHz — and it was the cleanest dataset in this file (CoV ≤ 0.6 % on
every row, services stopped, `performance` governor). Notably this was the Nix
flake build running from a deployed profile, not a tree build — same numbers
pedigree, different packaging path.

**¶ G720 `compile500` inversion.** Runtime compilation is the *one* row where
the G720 (16.9 ms) is slower than the Pi 5 (13.5 ms), despite winning every
other row by ~1.5×. CoV 0.2 % rules out big.LITTLE scheduling jitter (a run
bouncing between the A78 and A55 clusters would show variance, not a stable
median). The suspect is costlier I/D cache maintenance (`__clear_cache` after
each JIT emission) on this SoC's cache hierarchy — the same per-emission cost
structure flagged for x86-64 (‡), much milder here. Worth a look if JIT-heavy
workloads matter on this target.

**‡ x86-64 runtime compilation is ~5× slower than arm64.** The x86-64 machine-
code emitter compiles `compile500` in 66.7 ms vs 9–13.5 ms on the arm64 builds
— consistent across three independent nix x86-64 builds, and *not* a nix or
measurement artifact (a nix **arm64** build compiles in 12.5 ms, same as
native). A genuine x86-64-backend code-emission cost, worth investigating; it is
the only workload where the arm64 backend clearly beats x86-64.

**◊ M2 variance.** macOS schedules a CPU-bound process across performance and
efficiency cores (no pinning without elevated privileges), so `closures1M` and
`gc20` show CoV 4–5 % on the M2; their `min`s (39.6 ms / 26 ms) are the clean
P-core times. All other M2 rows are < 1 % CoV.

**VF (RISC-V / StarFive VisionFive).** The dual U74 is an **in-order ~1 GHz**
core on an early, modest dev board, so it runs **~8–15× the Pi 5** on the
call/loop/alloc/compile rows and **~30×** on the GC-bound `gc20` (1.39 s) — an
absolute-floor "it runs natively on RISC-V silicon" data point, not a competitive
number. The *shape* still tracks the faster machines (compile-to-machine-code
≈ a call workload; `gc20` is the slowest row) and CoV is < 5 % throughout — the
engine behaves correctly, just on slow silicon.

**`closures1M` on the StarFive — fixed an i-cache coherency bug.** This row
originally crashed (SIGILL). Heavy short-lived closure creation under auto-GC is
the trigger: closures are *executable heap objects*, and when the GC churns them
an address is reused for a new closure whose freshly written code is still stale
in the instruction cache at call time (memory holds a valid `auipc`; the i-cache
does not). It was **real-hardware-only** — QEMU re-translates self-modified code,
so it never appeared in emulation (exactly the `fence.i` / i-cache hazard the
port notes flag). The four-language validation was always green
(`validate-riscv64.sh` = 14/14); this was a closure-churn stress path, not a
functional regression. **Fixed** by hardening the i-cache flush (`CACHEFLUSH` →
`rv_cacheflush`: `fence rw,rw` + `__clear_cache` + `fence.i`) so the code stores
drain to the point of unification before the i-cache is invalidated. Verified at
1M closures × 20 runs and 10M × 5 runs (150M churned closures, zero faults; the
unhardened build crashed 5/5 at 1M) — and the fixed build now rebuilds all four
language images, including the JIT-heavy clisp, in seconds. See
`PORTING-RISCV64-LINUX.md`.

## Cross-language baselines (same workloads)

Per machine, **Poplog's median per-iteration time** and each baseline's
**slowdown ratio vs Poplog** (>1 = the baseline is that many × slower than
Poplog; <1 = faster than Poplog). Every ratio's bootstrap 95 % CI is tight
(±1–2 %); only ratios whose CI brackets 1.0 are *not* significant, and those are
called out as ties. `—` = workload not implemented for that engine.

**Intel i7-9700K (x86-64)** — vs CPython 3.10 (distro), 3.13.0rc2 (uv/PGO), Perl:

| Workload | Poplog | Python 3.10 | Python 3.13 | Perl 5.34 |
|---|---|---|---|---|
| nfib29 | 14.5 ms | 8.56× | **3.67×** | 13.8× |
| intloop10M | 61.5 ms | 6.26× | **5.60×** | 2.65× |
| lists | 11.4 ms | 7.76× | **7.20×** | — |
| closures1M | 22.0 ms | 3.00× | **2.13×** | — |
| gc20 | 20.4 ms | 0.50× | 0.48× | — |
| strings | 2.15 ms | 0.34× | 1.00× (tie) | — |
| compile500 ‡ | 66.7 ms | 0.08× | 0.12× | — |

**Apple M2 (arm64)** — vs CPython 3.14, Perl:

| Workload | Poplog | Python 3.14 | Perl 5.34 |
|---|---|---|---|
| nfib29 | 13.2 ms | **5.14×** | 13.6× |
| intloop10M | 52.2 ms | **5.56×** | 3.09× |
| lists | 9.0 ms | **7.09×** | — |
| closures1M ◊ | 45.1 ms | 1.04× (tie) | — |
| gc20 ◊ | 28.4 ms | 0.35× | — |
| strings | 1.94 ms | 0.43× | — |
| compile500 | 9.0 ms | 0.58× | — |

**Raspberry Pi 5 (arm64)** — vs CPython 3.13.5, Perl:

| Workload | Poplog | Python 3.13 | Perl 5.40 |
|---|---|---|---|
| nfib29 | 24.9 ms | **5.07×** | 15.7× |
| intloop10M | 124 ms | **4.94×** | 3.09× |
| lists | 22.2 ms | **5.46×** | — |
| closures1M | 33.5 ms | **2.46×** | — |
| gc20 | 48.1 ms | 0.36× | — |
| strings | 4.12 ms | 1.02× (tie) | — |
| compile500 | 13.5 ms | 0.79× | — |

**MediaTek Genio 720 (arm64)** — vs CPython 3.12.13, Perl 5.42:

| Workload | Poplog | Python 3.12 | Perl 5.42 |
|---|---|---|---|
| nfib29 | 16.4 ms | **5.69×** | 19.9× |
| intloop10M | 80.4 ms | **6.54×** | 3.22× |
| lists | 15.2 ms | **8.33×** | — |
| closures1M | 28.6 ms | **2.90×** | — |
| gc20 | 32.2 ms | 0.69× | — |
| strings | 2.54 ms | **1.50×** | — |
| compile500 ¶ | 16.9 ms | 0.99× (~tie) | — |

The G720 shows the *widest* Poplog margins of any machine in this file (lists
**8.33×**, loops **6.54×**) — partly real, partly baseline: its distro CPython
is **3.12**, predating the 3.13/3.14 interpreter speedups that compress the
ratios on the Apple machines. Same lesson as the i7's two-Python comparison:
interpreter build matters as much as hardware. Note `strings` is a clear Poplog
win here (1.50×) where the Pi 5 tied, and `compile500` is a statistical
near-tie with Pop emitting machine code vs CPython's bytecode.

**Apple M5 Pro (arm64)** — vs CPython 3.14, Perl 5.34:

| Workload | Poplog | Python 3.14 | Perl 5.34 |
|---|---|---|---|
| nfib29 | 8.83 ms | **3.92×** | 12.0× |
| intloop10M | 42.4 ms | **3.37×** | 1.91× |
| lists | 7.54 ms | **4.74×** | — |
| closures1M | 27.3 ms | 0.90× | — |
| gc20 | 12.0 ms | 0.56× | — |
| strings | 0.767 ms | 0.68× | — |
| compile500 | 5.52 ms | 0.63× | — |

On the M5, Poplog still wins the fundamentals (calls **3.92×**, loops **3.37×**,
lists **4.74×**) but by a *narrower* margin than on the M2/Pi5 (5–7×): the same
Python 3.14 sped up ~2× from M2→M5 while Poplog sped up ~1.5×, so the ratios
compress. `closures1M` even flips to a slight Poplog loss (**0.90×**) — the only
Apple-Silicon row where Python edges ahead. The likely cause is the macOS
dual-map **W^X "one fault per cross-procedure call"** cost (see
`PORTING-ARM64-M-SILICON-OSX.md`): call- and closure-heavy work pays a
per-invocation overhead that does *not* shrink with faster silicon, whereas
CPython's interpreter loop scales with raw core speed. This is the clearest
signal yet for the Phase-4 perf item (bias `PD_EXECUTE` to retire the per-call
redirect); on Linux arm64 (Pi5, no W^X dual-map) closures stay a clean **2.46×**
Poplog win.

---

## Windows 11 (experimental port)

Added 2026-11. The Windows port lives on the `windows-checkout` branch and is
experimental, so its numbers are kept apart from the six machines above
rather than threaded through their tables. Same harness, same workloads, same
Poplog version (160200).

**System under test (W11).** Dell G15 5520: Intel Core i5-12500H (Alder Lake,
2022; 4 performance + 8 efficiency cores, 16 threads), 15.7 GiB RAM, L2
9 MiB, L3 18 MiB. Windows 11 Home build 26300, "Balanced" power plan, on AC.
Poplog is the native Cygwin build (`PE32+ … x86-64`, Cygwin 3.6.12, gcc
14.4.0), with the graphics backend linked in. Baselines: CPython **3.12.0**
(the python.org Windows build, run natively, not under Cygwin) and Perl
**5.44** (Cygwin).

**How it was run.** `tools/bench-poplog.p` and the two baseline scripts, one
after another, each **pinned to one performance core** (affinity mask 4) at
High priority. `tools/bench.sh` was not used as it stands: it has no way to
pin, and on this CPU that matters (below).

| Workload | Poplog W11 | CoV | Python 3.12 (native) | Perl 5.44 |
|---|---|---|---|---|
| nfib29 (calls) | 10.1 ms | 0.7 % | **5.35×** | 13.2× |
| intloop10M | 46.6 ms | 0.5 % | **5.11×** | 2.42× |
| lists (alloc/GC) | 7.18 ms | 0.8 % | **9.19×** | — |
| closures1M | 34.0 ms | 1.3 % | 1.26× | — |
| gc20 | 21.1 ms | 2.2 % | 0.28× | — |
| strings | 0.824 ms | 1.0 % | 0.68× | — |
| compile500 (→ machine code) | 57.2 ms | 0.7 % | 0.10× | — |

Ratios are the baseline's slowdown against Poplog on the same machine
(>1 = slower than Poplog), as in the tables above; every ratio's 95 % CI is
within ±2 %.

**Reading it.**

- The cross-language pattern is the one every other machine shows: Poplog's
  native code is 5–9× CPython on calls, integer loops and list building,
  CPython wins on `gc20`, `strings` and above all `compile500`, and Perl sits
  where it does everywhere else (13×, 2.4×). Nothing about the Windows build
  moves a workload from one side of that line to the other.
- `compile500` at 57 ms carries the same x86-64 penalty as the i7's 66.7 ms
  (‡): it is the x86-64 code emitter, not the operating system.
- Against the other machines the absolute times say little: this is a newer
  CPU than the i7 and the environment is not comparable. They are **not** a
  Windows-versus-Linux comparison; that needs the same machine booted both
  ways, which has not been done.
- `closures1M` is the one row where this machine is slower than the i7
  (34.0 ms against 22.0 ms) while being faster on everything else. Unexplained.
  The Mac rows show that this workload is sensitive to how procedure records
  are laid out and executed, so it may be Windows-specific or may not.

**Three things that bit, for anyone repeating this.**

- **Pin it.** Unpinned, on a CPU with two kinds of core, the first run had
  run-to-run variation of 2–20 % (against under 1 % here) and `gc20` read
  30.6 ms instead of 21.1 ms: a third of its batches had landed on efficiency
  cores. The same effect as the M2's ◊ rows, larger.
- **Do not use Cygwin's Python as the baseline.** It was measured too (3.12.12,
  unpinned): it is a little faster than the native build on `nfib29` (0.78×)
  but 3.4–6.3× slower on `intloop10M`, `lists`, `compile500`, `closures1M`
  and `strings`, which would flatter Poplog by the same factors.
  The interpreter *build* matters as much as the version, here more than
  anywhere.
- **The CPU clock ticks every 15.6 ms on Windows.** `tools/bench-baseline.py`
  treated a batch too short to time as having taken a microsecond and jumped
  to two million iterations; one workload then ran for most of an hour. It
  now doubles instead, as the Perl script always did. The Poplog script was
  already safe, since `systime` is in centiseconds and it never divides by
  less than one.

---

## Analysis

* **Poplog wins the engine fundamentals on every machine, with confidence.**
  Against the *best available* CPython on each box, Poplog is **3.4–7.2×** faster
  on procedure calls, tight loops, and allocation/lists, and **2.1–3.0×** on
  closures (i7/Pi5) — all with sub-1 % variance and CIs that exclude 1.0. That is
  the defensible claim: *interactive like Python, native-code fast.* (Against the
  more common, non-PGO CPython 3.10, the call gap is **8.6×**.) **On the M5 Pro
  the fundamentals win narrows (3.4–4.7×) and `closures1M` slips to a slight loss
  (0.90×)** — a macOS dual-map W^X per-call cost that does not scale away with
  faster silicon (see the M5 cross-language table and Phase-4 note), not an
  engine regression: Linux arm64 keeps the clean closures win.
* **`compile500` is the one engine loss, and it is x86-64-specific.** Poplog's
  incremental compiler emits **machine code** where Python's `compile()` emits
  **bytecode** (Pop does strictly more work), so this is already an unequal
  comparison. The *arm64* backend is competitive (0.58–0.79×); the *x86-64*
  backend is ~5× slower at code emission (‡ above) and loses clearly here. A real
  x86-64-codegen item, not a whole-engine weakness.
* **`gc20` Python always wins.** CPython refcounting makes `gc.collect()` cheap
  on an acyclic heap; Pop runs a real moving collector — different mechanisms,
  not a decisive row.
* **`strings` is a wash.** Roughly a tie against modern CPython (both fall to
  C-level string code); CPython 3.10 happens to be quickest here, and the
  3.13.0rc2 build looks regressed on `str.find` vs 3.10.
* **Interpreter build matters as much as version.** On the same i7, `nfib29`
  costs **8.56×** vs CPython 3.10 but **3.67×** vs the PGO 3.13 build — a 2.3×
  spread from build configuration alone. Always name the interpreter build.
* **Perl** trails everywhere (calls 13.6–15.7×) and maps only the two workloads
  it can express cleanly.

---

## Threats to validity

1. **Cross-language semantics are not identical.** `compile500` (machine code
   vs bytecode) and `gc20` (moving GC vs refcounting) compare *analogous*, not
   identical, operations — annotated in [Workloads](#workloads). These are the
   only rows Python wins, and both are documented mechanism differences.
2. **Core pinning.** The Pi 5 and G720 ran under the `performance` governor and
   are the cleanest datasets (CoV ≤ 0.2 % / ≤ 0.6 %). The G720 is big.LITTLE
   (2×A78 + 6×A55) with no explicit pinning, but the stable medians and its
   ~1.5×-the-Pi 5 results indicate the single-threaded runs stayed on the A78
   cluster; its resident services (a voice-assistant stack) were stopped for
   the collection. The i7 ran `powersave` (intel_pstate boosts
   under sustained load, so this is close to performance for a multi-second
   batch). The **M2 could not be pinned to P-cores** without elevated privileges,
   giving CoV 4–5 % on `closures1M`/`gc20` (◊) — their `min`s are the clean
   P-core times. Ratios are unaffected by the governor (all engines share it).
3. **x86-64 compile-speed outlier (‡).** `compile500` on x86-64 is ~5× the arm64
   cost; isolated to the x86-64 code emitter (not nix, not measurement). A real
   item to investigate, flagged rather than averaged away.
4. **Single Poplog version, mixed Python builds.** All machines ran Poplog
   160200, but Python build/version differs per machine (named per row);
   interpreter *build* moves results 2–3× (see [Analysis](#analysis)), so
   cross-machine Python cells are not directly comparable.
5. **The QEMU/binfmt arch trap (caught here).** A wrong-architecture engine is
   the dangerous failure mode: an **aarch64** `basepop11` left in the tree runs
   transparently under `qemu-aarch64` and produces plausible-but-meaningless
   numbers (an earlier revision of this file fell for exactly this — it "matched"
   an explicit QEMU run because it *was* the same thing twice). **`tools/bench.sh`
   prints `file` of the engine before every run** and that guard fired on this
   i7 collection — the repo `basepop11` was aarch64-under-qemu, so the verified
   nix x86-64 build was used instead. Always check the arch line.

---

## Forth

Poplog Forth (a fifth language added in this fork — see the
[README](README.md)) compiles colon definitions to **native code**: `: name … ;` transpiles to a Pop-11 procedure
and goes through the same incremental compiler as everything above, so a Forth
word *is* a machine-code procedure and inherits the engine numbers in this
report. It is pure Pop-11, so it runs on every platform Poplog does; the
built-in `testbench` is **21/21** on macOS arm64 and on the RISC-V StarFive
VisionFive.

Its own micro-benchmark (`tools/forth.sh -b`) is a separate, lighter
instrument than the engine suite above — **wall-clock** (`sys_microtime`), a
single timed run, not the CPU-time median-of-30 methodology — so treat it as
indicative, not directly comparable to the tables. It times three native
colon-defs; on the **M5 Pro** (macOS arm64):

| Forth workload | M5 Pro |
|---|---|
| `fib(32)` (recursive) | ~161 ms |
| `count` to 50,000,000 (`do/loop`) | ~98 ms |
| `sum` to 50,000,000 (`do/loop` + accumulate) | ~126 ms |
| total | ~385 ms |

The shape tracks the engine results — recursion-heavy `fib` dominates, the
counted loops are cheaper — confirming colon-defs really are native procedures
rather than threaded code.

## Reproducing

Clear the decks first (close browsers/apps; on Linux set the CPU governor to
`performance`), then run the full suite on each machine:

```sh
./tools/bench.sh                         # SUT capture + all engines + stats + comparison
./tools/bench.sh /path/to/basepop11      # benchmark a specific engine
PYTHON=python3.13 ./tools/bench.sh        # pick the Python build (name it in the report!)
BENCH_RUNS=50 BENCH_MINTIME=3 ./tools/bench.sh   # more rigour (longer runtime)
```

Quick single-engine check, or feeding the aggregator directly:

```sh
./tools/bench-poplog.sh                  # Poplog only, with stats; prints engine arch -- CHECK IT
./poplog ./target/pop/basepop11 < tools/bench-poplog.p | python3 tools/bench-aggregate.py
python3 tools/bench-aggregate.py run1.samples run2.samples   # compare saved sample files
# QEMU (binfmt-mediated): QEMU_LD_PREFIX=<sysroot> <foreign binary> < tools/bench-poplog.p
```

`bench.sh` prints `file` of the engine before running, so a wrong-architecture
engine (the failure mode in [Threats to validity](#threats-to-validity) #5) is
caught immediately. Workloads are fixed in the three `tools/bench-*` scripts;
keep them identical across platforms for comparability. To compare several
Python builds on one machine, run the baseline under each and pass all the
`.samples` files to `bench-aggregate.py` (as was done for the i7 row).

## Pending datapoints

* **Investigate the x86-64 `compile500` slowdown (‡)** — the code emitter is
  ~5× the arm64 cost; the only workload where arm64 clearly beats x86-64.
* **P-core-pinned M2 re-run** (e.g. via a high-QoS / `taskpolicy` launch) to
  remove the ◊ variance on `closures1M`/`gc20`.
* A **real Raspberry Pi 3** (or MediaTek Genio-class arm64) for the low-power
  tier, to add a native low-power datapoint.
* A reliable **wall-clock** µs timer for Poplog (fix or work around the Darwin
  `sys_microtime` bug) if a wall-time cross-check is ever wanted alongside the
  CPU-time numbers.
