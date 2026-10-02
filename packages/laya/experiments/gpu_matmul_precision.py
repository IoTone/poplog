"""How exact is MLX's float32 matmul on this GPU?

    uv run --project packages/laya python packages/laya/experiments/gpu_matmul_precision.py OUT.json

Found while checking E5's in-Poplog result: the GPU answer differed from the exact one by
far more than float32 rounding, and Python MLX gave the same GPU answer, so it is MLX's
behaviour here rather than anything Poplog did. The input is deliberately hard -- values up
to 2.6e5 whose low bits carry the answer -- so read this as a bound on what float32 on the
GPU guarantees, not a typical error.
"""

import json
import sys

import mlx.core as mx
import numpy as np


def main():
    x = np.arange(262144, dtype=np.float64).reshape(512, 512)
    exact = x @ x
    report = {"device": mx.device_info().get("device_name", ""), "mlx": mx.__version__}
    for device in (mx.gpu, mx.cpu):
        with mx.stream(device):
            a = mx.arange(0.0, 262144.0, 1.0, dtype=mx.float32).reshape(512, 512)
            y = mx.matmul(a, a)
            mx.eval(y)
        y = np.array(y, dtype=np.float64)
        report[str(device)] = {
            "max_relative_error": float((np.abs(y - exact) / np.abs(exact)).max()),
            "row0_last": float(y[0, -1]),
        }
    report["exact_row0_last"] = float(exact[0, -1])
    with open(sys.argv[1], "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
