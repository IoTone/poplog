"""E7: summarise jev_order.p's output -- is the model order-sensitive?

    uv run --project packages/laya python packages/laya/experiments/jev_order_report.py RAW.json

Reads what jev_order.p wrote and answers three questions in order, because the later
ones only mean something if the first comes out clean:

  control  repeating the identical request -- does the model give the identical answer?
           Any spread here is the model's own noise, and it is the floor against which
           an ordering effect has to be judged.  A model that disagrees with itself
           cannot be shown to disagree because of order.
  g3       reordering the choice options -- does the pick change?  Does the probability
           of a given label move, and by more than the control's noise?
  g4       reordering the questions in one request -- does any answer change?

Prints one JSON object.  Exit status is 0 whatever the finding: "the model is order
sensitive" is a result, not a failure.  It is 1 only if the run itself was broken --
a call that errored, or a missing case.
"""

import json
import sys


def leaves(x, prefix=""):
    """Every leaf of an answer as (path, value)."""
    if isinstance(x, dict):
        for k, v in sorted(x.items()):
            yield from leaves(v, prefix + "/" + k)
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from leaves(v, prefix + "/%d" % i)
    else:
        yield prefix, x


def spread(answers):
    """Largest absolute difference at any numeric leaf, and the worst path.

    Non-numeric leaves that differ are reported separately: a changed `choice` is a
    categorical difference, not a small one, and averaging it into a float would hide it.
    """
    worst, where, categorical = 0.0, None, set()
    if not answers:
        return worst, where, categorical
    base = dict(leaves(answers[0]))
    for other in answers[1:]:
        for path, v in leaves(other):
            w = base.get(path)
            if (
                isinstance(v, (int, float))
                and isinstance(w, (int, float))
                and not isinstance(v, bool)
            ):
                if abs(v - w) > worst:
                    worst, where = abs(v - w), path
            elif v != w:
                categorical.add(path)
    return worst, where, categorical


def errors_in(raw):
    out = []
    for section in ("control", "g3_option_order", "g4_question_order"):
        for case, rows in raw.get(section, {}).items():
            items = rows if isinstance(rows, list) else list(rows.values())
            for row in items:
                if "error" in row:
                    out.append("%s/%s: %s" % (section, case, row["error"]))
                elif "answers" not in row:
                    out.append("%s/%s: no answers" % (section, case))
    return out


def main():
    raw = json.load(open(sys.argv[1]))
    problems = errors_in(raw)

    control = {}
    for case, rows in raw.get("control", {}).items():
        worst, where, cat = spread([r.get("answers", {}) for r in rows])
        control[case] = {
            "repeats": len(rows),
            "identical": worst == 0.0 and not cat,
            "max_numeric_spread": worst,
            "worst_field": where,
            "fields_that_changed_categorically": sorted(cat),
        }
    noise = max([c["max_numeric_spread"] for c in control.values()] or [0.0])

    g3 = {}
    for case, rows in raw.get("g3_option_order", {}).items():
        answers = [r["answers"]["team"] for r in rows.values() if "answers" in r]
        worst, where, cat = spread(answers)
        picks = sorted({a.get("choice") for a in answers})
        written = rows.get("123", {}).get("answers", {}).get("team", {}).get("choice")
        g3[case] = {
            "orderings": len(answers),
            "distinct_picks": picks,
            "pick_changed": len(picks) > 1,
            "pick_in_written_order": written,
            "max_numeric_spread": worst,
            "worst_field": where,
            "above_control_noise": worst > noise,
        }

    g4 = {}
    for case, rows in raw.get("g4_question_order", {}).items():
        per_question = {}
        ids = set()
        for r in rows.values():
            ids |= set(r.get("answers", {}))
        for qid in sorted(ids):
            answers = [r["answers"][qid] for r in rows.values() if qid in r.get("answers", {})]
            worst, where, cat = spread(answers)
            per_question[qid] = {
                "orderings": len(answers),
                "max_numeric_spread": worst,
                "worst_field": where,
                "fields_that_changed_categorically": sorted(cat),
                "above_control_noise": worst > noise,
            }
        g4[case] = per_question

    sensitive_g3 = any(c["pick_changed"] or c["above_control_noise"] for c in g3.values())
    sensitive_g4 = any(
        q["above_control_noise"] or q["fields_that_changed_categorically"]
        for case in g4.values()
        for q in case.values()
    )
    print(
        json.dumps(
            {
                "base_url": raw.get("base_url"),
                "model_asked": raw.get("model_asked"),
                "model_reported": sorted(
                    {
                        r.get("model")
                        for rows in raw.get("control", {}).values()
                        for r in rows
                        if r.get("model")
                    }
                ),
                "calls": raw.get("calls"),
                "deterministic_on_repeat": all(c["identical"] for c in control.values()),
                "control_noise": noise,
                "option_order_matters": sensitive_g3,
                "question_order_matters": sensitive_g4,
                "control": control,
                "g3_option_order": g3,
                "g4_question_order": g4,
                "problems": problems,
            },
            indent=1,
        )
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
