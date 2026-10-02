"""E3: what does calling Laya from Pop-11 cost on top of Laya itself?

    uv run --project packages/laya python packages/laya/experiments/latency.py \
        --out packages/laya/experiments/results/latency.json     # from the Poplog root

Times one request -- the benchmark's one short question -- through these paths:

    python    Agent.predict in this process (context: the model's own time)
    stdio     Pop-11 ts_eval -> LIB LAYA -> laya_serve.py --stdio
    http      Pop-11 ts_eval -> LIB HTTP_CLIENT (libcurl) -> laya_serve.py --port
    py-http   Python urllib -> the same HTTP server (separates server from client cost)
    encode / decode   Pop-11 ts_request / ts_decode alone, no transport

Overhead is paired: the server (timed_serve.py) reports its own time for each request, and
overhead is the client's time for that same call minus it. Machine load moves both together,
so the difference stays meaningful on a busy machine where absolute latencies do not.
"""

import argparse
import json
import os
import platform
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import warnings
from pathlib import Path

from laya_mlx import Agent

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from laya_serve import checkpoint  # noqa: E402

HERE = Path(__file__).resolve().parent
POPLOG = HERE.parents[2]
# The request: laya-mlx's benchmarks.common.workload(1) at 0a85951, saved, since the PyPI
# package does not ship benchmarks/.
REQUEST = HERE / "fixtures" / "latency-request.json"
PYTHON = sys.executable
TIMED_SERVE = str(Path(__file__).with_name("timed_serve.py"))


def summary(ns):
    ms = sorted(v / 1e6 for v in ns)
    if not ms:
        return None
    return {
        "n": len(ms),
        "p50_ms": round(statistics.median(ms), 3),
        "p95_ms": round(ms[int(0.95 * (len(ms) - 1))], 3),
        "mean_ms": round(statistics.fmean(ms), 3),
    }


def timed(fn, n, warmup):
    for _ in range(warmup):
        fn()
    samples = []
    for _ in range(n):
        t0 = time.perf_counter_ns()
        fn()
        samples.append(time.perf_counter_ns() - t0)
    return samples


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def pop11(args, mode, request_path, launcher, port=None):
    out = Path(tempfile.mkstemp(suffix=".json")[1])
    env = dict(
        os.environ,
        LATENCY_MODE=mode,
        LATENCY_N=str(args.n),
        LATENCY_WARMUP=str(args.warmup),
        LATENCY_REQUEST=str(request_path),
        LATENCY_OUT=str(out),
        LATENCY_PORT=str(port or 0),
        LAYA_MODEL=args.model,
        LAYA_DTYPE=args.dtype,
        LAYA_SERVER=str(launcher),
    )
    script = str(Path(__file__).with_name("latency.p"))
    proc = subprocess.run(
        ["./poplog", "./target/pop/basepop11", script],
        cwd=args.poplog,
        env=env,
        capture_output=True,
        text=True,
        timeout=3600,
    )
    if "LATENCY-DONE" not in proc.stdout:
        sys.exit("Pop-11 %s run failed:\n%s\n%s" % (mode, proc.stdout[-2000:], proc.stderr[-2000:]))
    return json.loads(out.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poplog", type=Path, default=POPLOG)
    parser.add_argument("--model", default="aac6fef/laya-mlx")
    parser.add_argument("--dtype", default="float16")
    parser.add_argument("--n", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    request = json.loads(REQUEST.read_text())
    state, questions = request["state"], request["questions"]
    request_path = Path(tempfile.mkstemp(suffix=".json")[1])
    request_path.write_text(json.dumps(request, ensure_ascii=False))
    body = json.dumps({**request, "model": "laya"}).encode()

    # LIB LAYA runs one command; this one is laya_serve.py with per-request server time.
    launcher = Path(tempfile.mkdtemp()) / "laya-mlx-timed"
    launcher.write_text('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (PYTHON, TIMED_SERVE))
    launcher.chmod(0o755)

    def paired(total, server):
        return summary([t - s for t, s in zip(total, server)])

    warnings.simplefilter("ignore", RuntimeWarning)
    agent = Agent(args.model, dtype=args.dtype)
    rounds = []
    for r in range(args.rounds):
        result = {}
        result["python"] = summary(
            timed(lambda: agent.predict(state, questions), args.n, args.warmup)
        )
        got = pop11(args, "stdio", request_path, launcher)
        result["stdio"] = summary(got["calls_ns"])
        result["stdio-server"] = summary(got["server_ns"])
        result["stdio-overhead"] = paired(got["calls_ns"], got["server_ns"])
        result["encode"] = summary(got["encode_ns"])
        result["decode"] = summary(got["decode_ns"])

        port = free_port()
        server = subprocess.Popen(
            [launcher, "--model", args.model, "--dtype", args.dtype, "--port", str(port)],
            stderr=subprocess.DEVNULL,
        )
        try:
            url = "http://127.0.0.1:%d/v1" % port
            for _ in range(600):
                try:
                    urllib.request.urlopen(url + "/health", timeout=1).read()
                    break
                except OSError:
                    time.sleep(0.1)

            server_ns = []

            def post():
                req = urllib.request.Request(
                    url + "/systemone", data=body, headers={"Content-Type": "application/json"}
                )
                server_ns.append(
                    json.loads(urllib.request.urlopen(req, timeout=30).read())["server_ns"]
                )

            total = timed(post, args.n, args.warmup)
            server_ns = server_ns[args.warmup :]
            result["py-http"] = summary(total)
            result["py-http-overhead"] = paired(total, server_ns)
            got = pop11(args, "http", request_path, launcher, port)
            result["http"] = summary(got["calls_ns"])
            result["http-server"] = summary(got["server_ns"])
            result["http-overhead"] = paired(got["calls_ns"], got["server_ns"])
        finally:
            server.terminate()
            server.wait()
        for k, v in result.items():
            print("round %d %-8s %s" % (r + 1, k, v), flush=True)
        rounds.append(result)

    def across(key, stat):
        return round(statistics.median(r[key][stat] for r in rounds), 3)

    report = {
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "machine": platform.platform(),
        "model": checkpoint(agent),
        "workload": "fixtures/latency-request.json: laya-mlx workload(1), one question",
        "n": args.n,
        "warmup": args.warmup,
        "rounds": rounds,
        "load_average_at_end": os.getloadavg(),
        "paired_overhead_ms_median_of_rounds": {
            k: {"p50": across(k + "-overhead", "p50_ms"), "p95": across(k + "-overhead", "p95_ms")}
            for k in ("stdio", "http", "py-http")
        },
        "pop11_json_ms_median_of_rounds": {k: across(k, "p50_ms") for k in ("encode", "decode")},
    }
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["paired_overhead_ms_median_of_rounds"]))


if __name__ == "__main__":
    main()
