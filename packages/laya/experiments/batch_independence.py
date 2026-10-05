"""Does a question's answer depend on the other questions in its request?

    uv run --project packages/laya python packages/laya/experiments/batch_independence.py \
        packages/laya/experiments/results/batch-independence.json

laya-mlx answers a request's questions in batches (batch_size, default 16), each padded to
its longest member. On a GPU the same question then gets slightly different numbers in
different company (RESEARCH.md §3.2). This measures, per configuration, how often an
answer differs -- in any field a user sees, at laya-mlx's 4-decimal rounding -- from the
same question asked alone, and what the configuration costs in time:

    default      batch_size=16, padded to the batch's longest member
    pad64        padded to a multiple of 64
    fixed        padded to the checkpoint's whole context (every batch the same length)
    fixed-shape  fixed, and every batch filled to 16 rows with a filler question, so
                 every forward pass has exactly the same shape
    alone        batch_size=1: every question its own forward pass
    default-fp32 the default in float32
    cpu-fp32     the default on the CPU (float32: float16 overflows there), a control

The reference for each question is its answer when asked alone, under the same
configuration and device.
"""

import json
import random
import statistics
import sys
import time
import warnings
from pathlib import Path

import mlx.core as mx
from laya_mlx import Agent

HERE = Path(__file__).resolve().parent
MODEL = "aac6fef/laya-mlx"
TRIALS = 200
SEED = 7


def pool():
    """The fixtures' distinct questions, plus a few of other lengths and shapes."""
    cases = json.loads((HERE / "fixtures/parity-requests.json").read_text())
    seen = {}
    for case in cases:
        for q in case["questions"].values():
            seen[json.dumps(q, sort_keys=True)] = q
    extra = [
        {"type": "noul", "instructions": "Is the customer angry?"},
        {
            "type": "choice",
            "instructions": "Which team should handle this?",
            "criteria": ["billing", "technical", "sales", "legal", "hr"],
        },
        {
            "type": "score",
            "instructions": "How likely is the customer to cancel?",
            "criteria": ["very unlikely", "unlikely", "even", "likely", "very likely"],
        },
        {"type": "noul", "instructions": "Does the message mention an invoice number?"},
        {
            "type": "choice",
            "instructions": "What is the tone of this email, considered as a whole, "
            "including the subject line and any implied deadline?",
            "criteria": {"calm": None, "frustrated": None, "hostile": None},
        },
    ]
    return list(seen.values()) + extra


FILLER = {"type": "noul", "instructions": "Filler."}


def run(agent, state, questions, fill=False):
    """Answers for QUESTIONS; with FILL, pad the request with filler questions to a
    whole number of batches, so every batch has batch_size rows."""
    if fill:
        questions = dict(questions)
        while len(questions) % agent.batch_size:
            questions["_filler%d" % len(questions)] = FILLER
    answers = agent.predict(state, questions)["answers"]
    return {k: v for k, v in answers.items() if not k.startswith("_filler")}


def measure(name, agent, state, qs, rng_seed, fill=False):
    rng = random.Random(rng_seed)
    alone = [run(agent, state, {"q": q}, fill)["q"] for q in qs]
    asked = differing = picks_changed = 0
    worst = 0.0
    for _ in range(TRIALS):
        k = rng.randint(2, 24)
        chosen = [rng.randrange(len(qs)) for _ in range(k)]
        answers = run(agent, state, {"q%d" % i: qs[j] for i, j in enumerate(chosen)}, fill)
        for i, j in enumerate(chosen):
            got, want = answers["q%d" % i], alone[j]
            asked += 1
            differing += got != want
            if want["type"] == "choice":
                picks_changed += got["choice"] != want["choice"]
            for key in ("probabilities",):
                for label, p in want.get(key, {}).items():
                    worst = max(worst, abs(p - got[key][label]))
            for key in ("noul", "score", "confidence"):
                if key in want:
                    worst = max(worst, abs(want[key] - got[key]))
    # time: a 1-question and a 16-question request, median of 30 after warmup
    timing = {}
    for size in (1, 16):
        request = {"q%d" % i: qs[i % len(qs)] for i in range(size)}
        for _ in range(5):
            run(agent, state, request, fill)
        samples = []
        for _ in range(30):
            t0 = time.perf_counter()
            run(agent, state, request, fill)
            samples.append((time.perf_counter() - t0) * 1000)
        timing["%d_question_ms" % size] = round(statistics.median(samples), 2)
    row = {
        "config": name,
        "answers_compared": asked,
        "answers_differing_from_alone": differing,
        "fraction_differing": round(differing / asked, 4),
        "choice_picks_changed": picks_changed,
        "max_abs_difference": round(worst, 4),
        **timing,
    }
    print(json.dumps(row), flush=True)
    return row


def main():
    warnings.simplefilter("ignore", RuntimeWarning)
    state = json.loads((HERE / "fixtures/parity-requests.json").read_text())[0]["state"]
    qs = pool()
    max_len = Agent(MODEL).cfg.get("max_len", 512)
    configs = [
        ("default", dict(), None, False),
        ("pad64", dict(pad_to_multiple=64), None, False),
        ("fixed", dict(pad_to_multiple=max_len), None, False),
        ("fixed-shape", dict(pad_to_multiple=max_len), None, True),
        ("alone", dict(batch_size=1), None, False),
        ("default-fp32", dict(dtype="float32"), None, False),
        ("cpu-fp32", dict(dtype="float32"), "cpu", False),
    ]
    rows = []
    for name, kwargs, device, fill in configs:
        agent = Agent(MODEL, device=device, **kwargs)
        rows.append(
            {**measure(name, agent, state, qs, SEED, fill), "dtype": agent.dtype.__repr__()}
        )
        del agent
        mx.clear_cache()
    report = {
        "model": MODEL,
        "dtype": "float16 unless the row says otherwise",
        "max_len": max_len,
        "pool_size": len(qs),
        "trials": TRIALS,
        "request_sizes": "2-24 questions, drawn with replacement, random order",
        "compared": "every answer field at laya-mlx's 4-decimal rounding, vs asked alone",
        "rows": rows,
    }
    Path(sys.argv[1]).write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
