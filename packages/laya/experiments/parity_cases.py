"""E1: write the validation fixtures as requests, and Python's answers for each checkpoint.

    uv run --project packages/laya python packages/laya/experiments/parity_cases.py OUT_DIR

OUT_DIR/requests.json is a list of {name, state, questions}; OUT_DIR/expected/<label>.json
maps each case name to `Agent.predict`'s result in this process. parity.p sends the same
requests through Pop-11 and `laya_serve.py --stdio`; compare.py checks the two agree.

The cases are laya-mlx's benchmarks.common.parity_cases() at 0a85951 (the published
validation fixtures: 16 cases, 63 questions), saved in fixtures/ because the PyPI package
does not ship benchmarks/.
"""

import json
import sys
import warnings
from pathlib import Path

from laya_mlx import Agent

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from laya_serve import checkpoint  # noqa: E402

CHECKPOINTS = {
    "laya": "aac6fef/laya-mlx",
    "laya-multilingual": "aac6fef/laya-multilingual-mlx",
    "laya-typed-decisions": "aac6fef/laya-typed-decisions-mlx",
}
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
    for label, repo in CHECKPOINTS.items():
        for dtype in DTYPES:
            agent = Agent(repo, dtype=dtype)
            expected = {c["name"]: agent.predict(c["state"], c["questions"]) for c in cases}
            expected["_checkpoint"] = checkpoint(agent)
            (out / "expected" / ("%s-%s.json" % (label, dtype))).write_text(
                json.dumps(expected, ensure_ascii=False)
            )
            print(label, dtype, checkpoint(agent), flush=True)


if __name__ == "__main__":
    main()
