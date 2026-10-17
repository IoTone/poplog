"""E1/E6: compare Pop-11's answers (parity.p) with Python's.

uv run --project packages/laya python packages/laya/experiments/compare.py EXPECTED.json POP11.json

E1 (parity_cases.py) answers every case with one checkpoint, named once in
`_checkpoint`.  E6 (router_cases.py) routes per case, so each case carries its own
`_model` and `_route`.  Both are checked the same way: the only difference is which
checkpoint string a case is expected to report.
"""

import json
import sys


def flat(answer, prefix=""):
    """Every leaf of an answer as (path, value)."""
    if isinstance(answer, dict):
        for k, v in answer.items():
            yield from flat(v, prefix + "/" + k)
    else:
        yield prefix, answer


def main():
    expected = json.load(open(sys.argv[1]))
    got = json.load(open(sys.argv[2]))
    # E1 names one checkpoint for the whole run; E6 names one per case.
    checkpoint = expected.pop("_checkpoint", None)
    questions = choices = picks = leaves = exact = 0
    worst = 0.0
    problems = []
    routes = {}
    seen_checkpoints = set()
    for name, want in expected.items():
        have = got.get(name)
        if have is None:
            problems.append("missing case " + name)
            continue
        route = want.pop("_route", None)
        if route is not None:
            routes.setdefault(route["model"], []).append(name)
        want_model = want.pop("_model", checkpoint)
        seen_checkpoints.add(want_model)
        if have["model"] != want_model:
            problems.append("%s: model %r != %r" % (name, have["model"], want_model))
        if have["usage"] != want["usage"]:
            problems.append("%s: usage %r != %r" % (name, have["usage"], want["usage"]))
        for qid, a in want["answers"].items():
            b = have["answers"].get(qid, {})
            questions += 1
            if a["type"] == "choice":
                choices += 1
                picks += a["choice"] == b.get("choice")
            bl = dict(flat(b))
            for path, v in flat(a):
                leaves += 1
                w = bl.get(path)
                if w == v:
                    exact += 1
                elif isinstance(v, (int, float)) and isinstance(w, (int, float)):
                    worst = max(worst, abs(v - w))
                else:
                    problems.append("%s/%s%s: %r != %r" % (name, qid, path, v, w))
    print(
        json.dumps(
            {
                "checkpoint": checkpoint or sorted(seen_checkpoints),
                "routed": {k: len(v) for k, v in sorted(routes.items())} or None,
                "questions": questions,
                "choice_questions": choices,
                "same_choice": picks,
                "fields": leaves,
                "fields_exactly_equal": exact,
                "max_abs_numeric_difference": worst,
                "problems": problems[:20],
            }
        )
    )
    return 1 if problems or picks != choices else 0


if __name__ == "__main__":
    sys.exit(main())
