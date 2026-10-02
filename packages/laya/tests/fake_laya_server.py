#!/usr/bin/env python3
"""Stand-in for `laya_serve.py --stdio`: same protocol, canned answers, no model.

Lets the Pop-11 tests exercise framing, errors and crash recovery without MLX.
A state of "CRASH" exits mid-request; "BAD" is answered with a 422 error.
Choice answers carry "order", the criteria keys in the order they arrived.
"""

import json
import sys

MODEL = "fake/laya@0000000 float16"

for line in sys.stdin:
    msg = json.loads(line)
    ident, method, params = msg["id"], msg["method"], msg.get("params")
    if method == "health":
        out = {"jsonrpc": "2.0", "id": ident, "result": {"status": "ok", "model": MODEL}}
    elif params.get("state") == "CRASH":
        sys.exit(3)
    elif params.get("state") == "BAD":
        error = {"code": -32602, "message": "ValueError: bad question", "data": {"status": 422}}
        out = {"jsonrpc": "2.0", "id": ident, "error": error}
    else:
        answers = {}
        for qid, q in params["questions"].items():
            if q["type"] == "choice":
                keys = list(q["criteria"])
                answers[qid] = {
                    "type": "choice",
                    "choice": keys[0],
                    "confidence": 0.5,
                    "order": keys,
                }
            elif q["type"] == "score":
                answers[qid] = {"type": "score", "score": 1.0, "confidence": 0.5}
            else:
                answers[qid] = {"type": "noul", "noul": 0.75, "confidence": 0.75}
        out = {
            "jsonrpc": "2.0",
            "id": ident,
            "result": {
                "model": MODEL,
                "answers": answers,
                "usage": {"input_tokens": len(json.dumps(params)), "output_tokens": 0},
            },
        }
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
