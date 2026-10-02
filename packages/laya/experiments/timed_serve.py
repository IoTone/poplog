"""`laya_serve.py` that also reports, per request, the time spent inside the server.

E3 subtracts this from the client's own timing of the same call, so transport overhead is
measured pair by pair and does not depend on how busy the machine was. The answers are
unchanged; `server_ns` is one extra top-level field.

    uv run --project packages/laya python packages/laya/experiments/timed_serve.py --stdio [...]
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import laya_serve as serve  # noqa: E402

_systemone = serve.Service.systemone


def timed_systemone(self, request):
    start = time.perf_counter_ns()
    result = _systemone(self, request)
    result["server_ns"] = time.perf_counter_ns() - start
    return result


serve.Service.systemone = timed_systemone

if __name__ == "__main__":
    serve.main(sys.argv[1:])
