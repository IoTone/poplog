"""Does the order of choice options change Laya's answer?

    uv run --project packages/laya python packages/laya/experiments/option_order.py packages/laya/experiments/results/option-order.json

Every permutation of the options, same text and instructions, on each published checkpoint.
This is why a client must send options in the order written: Pop-11's typesafe client sent
them in hash-table order until json_object.
"""

import itertools
import json
import sys
import warnings
from pathlib import Path

from laya_mlx import Agent

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from laya_serve import checkpoint  # noqa: E402

CHECKPOINTS = (
    "aac6fef/laya-mlx",
    "aac6fef/laya-multilingual-mlx",
    "aac6fef/laya-typed-decisions-mlx",
)
TEAMS3 = ["billing", "technical", "sales"]
TEAMS5 = TEAMS3 + ["legal", "hr"]
CASES = [
    ("I was billed twice. Please refund the duplicate.", TEAMS3, "Who should handle this?"),
    (
        "The app crashes when I upload a photo, and I'd also like a quote for 50 seats.",
        TEAMS5,
        "Which team should handle this?",
    ),
    ("Can you tell me more about pricing tiers?", TEAMS5, "Which team should handle this?"),
]


def main():
    warnings.simplefilter("ignore", RuntimeWarning)
    rows = []
    for repo in CHECKPOINTS:
        agent = Agent(repo)
        for state, labels, instructions in CASES:
            answers = {}
            for order in itertools.permutations(labels):
                q = {"type": "choice", "instructions": instructions, "criteria": list(order)}
                answers[order] = agent.predict(state, {"q": q})["answers"]["q"]
            written = answers[tuple(labels)]["choice"]
            spread = max(
                max(a["probabilities"][label] for a in answers.values())
                - min(a["probabilities"][label] for a in answers.values())
                for label in labels
            )
            row = {
                "checkpoint": checkpoint(agent),
                "state": state,
                "options": len(labels),
                "orderings": len(answers),
                "picks": sorted({a["choice"] for a in answers.values()}),
                "orderings_agreeing_with_written_order": sum(
                    a["choice"] == written for a in answers.values()
                ),
                "max_probability_spread": round(spread, 4),
            }
            rows.append(row)
            print(json.dumps(row), flush=True)
    with open(sys.argv[1], "w") as f:
        json.dump(rows, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
