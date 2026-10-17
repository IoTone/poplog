"""E6: write Python's answers for the router path, over the same cases as E1.

    uv run --project packages/laya python packages/laya/experiments/router_cases.py OUT_DIR

Same fixtures, same comparison, one difference: the predictor is `Router` rather than
`Agent`, so each case is answered by whichever checkpoint the router picks for it.  The
E1 fixtures already carry eight non-English cases (zh, de, fr, es, hi, ja, ru and the
`email`/`en` pair), which is exactly what makes them worth routing -- the router's own
documentation says the English checkpoint does not gently degrade off English, it
collapses, so a routing bug is a large accuracy bug and not a rounding one.

What this adds over the existing router tests: `tests/test_laya_serve.py` checks that a
routed response names its checkpoint, and RESEARCH.md records one live run.  Neither
compares the answers themselves.  This does, field by field, against Python in this
process -- the check E1 makes for the single-checkpoint path.

OUT_DIR/requests.json is the case list; OUT_DIR/expected/router-<dtype>.json maps each
case name to `Router.predict`'s result, with `routing` lifted out into `_model` (the
checkpoint string the server would report for that case) and `_route` (the decision, so
the write-up can show routing actually varied).  parity.p run with LAYA_ROUTER=1 sends
the same requests through Pop-11; compare.py checks the two agree.
"""

import json
import sys
import warnings
from pathlib import Path

from laya_mlx import Router

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from laya_serve import checkpoint  # noqa: E402

DTYPES = ("float16", "float32")


def main():
    out = Path(sys.argv[1])
    (out / "expected").mkdir(parents=True, exist_ok=True)
    cases = json.loads(
        (Path(__file__).resolve().parent / "fixtures/parity-requests.json").read_text()
    )
    (out / "requests.json").write_text(json.dumps(cases, ensure_ascii=False))
    print("%d cases, %d questions" % (len(cases), sum(len(c["questions"]) for c in cases)))
    warnings.simplefilter("ignore", RuntimeWarning)
    for dtype in DTYPES:
        # max_loaded=3 as laya_serve.py does: with cases alternating language, the
        # default of 1 would evict and rebuild a checkpoint on nearly every call.
        router = Router(dtype=dtype, max_loaded=3)
        expected = {}
        for case in cases:
            result = router.predict(case["state"], case["questions"])
            route = result.pop("routing")
            # The same string the server reports, by the same path: ask the router for
            # the Agent it routed to and name that.
            result["_model"] = checkpoint(router.load(route["model"]))
            result["_route"] = {"model": route.get("model"), "reason": route.get("reason")}
            expected[case["name"]] = result
        (out / "expected" / ("router-%s.json" % dtype)).write_text(
            json.dumps(expected, ensure_ascii=False)
        )
        picked = {}
        for name, result in expected.items():
            picked.setdefault(result["_route"]["model"], []).append(name)
        print(dtype, json.dumps(picked, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
