#!/usr/bin/env python3
"""Python baseline for tools/bench-poplog.p -- same seven workloads, same
rigorous protocol (CPU-time, auto-calibration, warm-up, N runs).

Timer: time.process_time() -- process CPU time (user+system), matching
Poplog systime() and Perl times().  Measuring CPU time (not wall) aligns the
three engines AND makes the numbers robust to background load.

Each workload is repeated K times per timed batch, K chosen so a batch takes
>= BENCH_MINTIME (default 2 s) of CPU time.  WARMUP batches are discarded,
then RUNS batches are emitted as:

    SAMPLE <workload> <batch-microseconds> <iterations-K>

plus META/CALIB lines.  tools/bench-aggregate.py computes the statistics.

Mapping caveats (documented, not hidden):
  * compile500 -- Python compile() builds *bytecode*; Pop compiles to
    *machine code* (Pop does MORE work, so parity favours Pop).
  * gc20       -- gc.collect() over a populated heap; CPython is refcount +
    cycle collector, Pop is a real moving GC -- closest available analogue.
  * intloop10M -- Python ints are boxed objects, like Pop items.
Tunables via environment: BENCH_RUNS, BENCH_WARMUP, BENCH_MINTIME (seconds).
"""
import gc
import os
import sys
import time

RUNS = int(os.environ.get("BENCH_RUNS", 30))
WARMUP = int(os.environ.get("BENCH_WARMUP", 3))
MINTIME = float(os.environ.get("BENCH_MINTIME", 2.0))   # seconds of CPU time

now = time.process_time


def runk(f, k):
    for _ in range(k):
        f()


def calibrate(f):
    k = 1
    while True:
        t0 = now(); runk(f, k); dt = now() - t0
        if dt >= MINTIME or k >= 100_000_000:
            return k
        # grow toward target from the measured rate (min 2x).  A batch too
        # short for the clock to see reads as zero; that says nothing about
        # the rate, so just double, as bench-baseline.pl does.  (Treating it
        # as a microsecond made k jump to two million on Windows, where the
        # CPU clock ticks every 15.6 ms: one batch of "strings" then took
        # the better part of an hour.)
        if dt <= 0:
            k *= 2
        else:
            k = max(k * 2, int(k * (MINTIME + 0.001) / dt))


def measure(name, f):
    k = calibrate(f)
    for _ in range(WARMUP):
        t0 = now(); runk(f, k); now()
    print(f"CALIB\t{name}\t{k}", flush=True)
    for _ in range(RUNS):
        t0 = now(); runk(f, k); dt = now() - t0
        print(f"SAMPLE\t{name}\t{round(dt * 1_000_000)}\t{k}", flush=True)


# ---- workloads (one call of each = one iteration / unit of work) ----------

sys.setrecursionlimit(100000)

def nfib(n):
    return 1 if n < 2 else nfib(n - 1) + nfib(n - 2) + 1
def w_nfib(): nfib(29)

def w_intloop():
    s = 0
    for i in range(1, 10_000_001):
        s = s + i

def w_lists():
    for _ in range(200):
        l = None
        for i in range(1, 5001):
            l = (i, l)
        p = l
        while p is not None:
            _x, p = p

SRC = "def tmp_b_p(x):\n    x = x * 2 + 1\n    return x\n"
def w_compile():
    for _ in range(500):
        compile(SRC, "<bench>", "exec")

_gc_keep = []
def w_gc():
    for _ in range(20):
        gc.collect()

def w_closures():
    for i in range(100000):
        c = (lambda v: lambda: v)(i)
        for _ in range(10):
            c()

def w_strings():
    s = "x"
    for _ in range(14):
        s = s + s
    for _ in range(200):
        s.find("zz")


# ---- driver ----------------------------------------------------------------

print(f"META\tengine=python\tversion={sys.version.split()[0]}"
      f"\truns={RUNS}\twarmup={WARMUP}\tmintime_s={MINTIME}"
      f"\ttimer=process_time-cpu", flush=True)

measure("nfib29", w_nfib)
measure("intloop10M", w_intloop)
measure("lists", w_lists)
measure("compile500", w_compile)

_gc_keep = [(1, 2) for _ in range(50000)]
measure("gc20", w_gc)
_gc_keep = []

measure("closures1M", w_closures)
measure("strings", w_strings)

print("bench-done python", sys.version.split()[0], flush=True)
