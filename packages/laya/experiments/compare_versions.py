"""Did moving the pins change Laya's answers?  Python's answers under two environments.

    uv run --project packages/laya python packages/laya/experiments/compare_versions.py \
        OLD_DIR NEW_DIR > packages/laya/experiments/results/pins-0.2.0-vs-0.9.1.jsonl

OLD_DIR and NEW_DIR are parity_cases.py output directories, each written in one
environment: NEW_DIR in this package's, OLD_DIR in a copy of it whose pyproject.toml pins
the previous versions (laya-mlx 0.2.0, mlx 0.32.2) and was relocked.  E1 compares Pop-11
with Python inside one environment, so it cannot see this.

One line per checkpoint and precision: how many answer fields both versions have and how
many are identical, how many choice picks changed, the largest numeric change and where,
the largest change per kind of field, and the fields only one version has.
"""

import json
import sys
from pathlib import Path


def flat(x, p=""):
    if isinstance(x, dict):
        for k, v in x.items():
            yield from flat(v, f"{p}.{k}" if p else k)
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from flat(v, f"{p}[{i}]")
    else:
        yield p, x


def kind(path):
    return "probabilities" if ".probabilities." in path else path.split(".")[-1]


def main():
    old, new = Path(sys.argv[1]), Path(sys.argv[2])
    for f in sorted((old / "expected").glob("*.json")):
        a = json.loads(f.read_text())
        b = json.loads((new / "expected" / f.name).read_text())
        common = same = picks = changed = 0
        only_old, only_new, by_kind = {}, {}, {}
        worst = (0.0, None)
        for case in (c for c in a if isinstance(a[c], dict)):
            fa, fb = dict(flat(a[case]["answers"])), dict(flat(b[case]["answers"]))
            for k in fa.keys() - fb.keys():
                only_old[kind(k)] = only_old.get(kind(k), 0) + 1
            for k in fb.keys() - fa.keys():
                only_new[kind(k)] = only_new.get(kind(k), 0) + 1
            for k in fa.keys() & fb.keys():
                common += 1
                va, vb = fa[k], fb[k]
                same += va == vb
                if k.endswith(".choice"):
                    picks += 1
                    changed += va != vb
                num = (int, float)
                if va != vb and isinstance(va, num) and isinstance(vb, num):
                    if not isinstance(va, bool):
                        d = abs(va - vb)
                        by_kind[kind(k)] = round(max(by_kind.get(kind(k), 0), d), 4)
                        if d > worst[0]:
                            worst = (d, f"{case}:{k}")
        print(
            json.dumps(
                {
                    "config": f.stem,
                    "fields_in_both": common,
                    "identical": same,
                    "choice_picks": picks,
                    "picks_changed": changed,
                    "largest_change": round(worst[0], 4),
                    "where": worst[1],
                    "largest_by_kind": dict(sorted(by_kind.items())),
                    "fields_only_old": only_old,
                    "fields_only_new": only_new,
                }
            )
        )


if __name__ == "__main__":
    main()
