"""E4: the reference side of "can Pop-11 drive the encoder through mlx-c?".

    uv run --project packages/laya python packages/laya/experiments/encoder_ref.py OUT_DIR [--cpu]           # ids + reference
    uv run --project packages/laya python packages/laya/experiments/encoder_ref.py OUT_DIR --compare         # after encoder_layers.p
    uv run --project packages/laya python packages/laya/experiments/encoder_ref.py GPU_DIR --spread CPU_DIR  # Python GPU vs CPU

Writes the token ids of a text long enough (> 64 tokens) for the sliding window to mask
something, and the English checkpoint's own FP32 outputs after the embeddings, layer 0
(global attention, no attention norm) and layer 1 (sliding window, with attention norm).
encoder_layers.p rebuilds the same computation in Pop-11 from the same weights file.
"""

import json
import sys
import warnings
from pathlib import Path

import mlx.core as mx
import numpy as np
from laya_mlx import Agent
from laya_mlx.model import attention_masks

TEXT = (
    "I was charged twice for invoice 4411 last month, and the duplicate payment has still not "
    "been refunded even though support promised it would be within five business days. "
    "I have attached the bank statement showing both withdrawals. Please refund the second "
    "charge today, and tell me why the first ticket was closed without an answer. If this "
    "cannot be resolved this week I will have to cancel the subscription for our whole team "
    "of forty people and dispute the charge with the bank directly."
)
STAGES = ("embeddings", "layer0", "layer1")


def main():
    out = Path(sys.argv[1])
    if "--compare" in sys.argv:
        compare(out)
        return
    if "--spread" in sys.argv:
        spread(out, Path(sys.argv[sys.argv.index("--spread") + 1]))
        return
    out.mkdir(parents=True, exist_ok=True)
    warnings.simplefilter("ignore", RuntimeWarning)
    agent = Agent(
        "aac6fef/laya-mlx", dtype="float32", device="cpu" if "--cpu" in sys.argv else None
    )
    enc = agent.model.encoder
    ids = [agent.tok.cls_token_id] + agent.tok(TEXT)["input_ids"] + [agent.tok.sep_token_id]
    x = mx.array([ids], dtype=mx.int32)
    with mx.stream(agent.device):
        masks = attention_masks(mx.ones(x.shape, dtype=mx.int32), enc.config.local_attention)
        h0 = enc.embeddings(x)
        h1 = enc.layers[0](h0, masks[enc.layers[0].attention_type])
        h2 = enc.layers[1](h1, masks[enc.layers[1].attention_type])
        mx.eval(h0, h1, h2)
    for name, value in zip(STAGES, (h0, h1, h2)):
        np.save(out / ("ref-%s.npy" % name), np.array(value))
    meta = {
        "ids": ids,
        "weights": str(agent.model_dir / "model.safetensors"),
        "layer_types": [enc.layers[0].attention_type, enc.layers[1].attention_type],
        "window": enc.config.local_attention,
    }
    (out / "meta.json").write_text(json.dumps(meta))
    (out / "ids.csv").write_text(",".join(map(str, ids)))
    print("%d tokens, layers %s" % (len(ids), meta["layer_types"]))


def compare(out):
    report = {}
    for name in STAGES:
        ref = np.load(out / ("ref-%s.npy" % name)).astype(np.float64)
        got = np.load(out / ("pop-%s.npy" % name)).astype(np.float64)
        err = np.abs(ref - got)
        report[name] = {
            "shape": list(ref.shape),
            "max_abs_error": float(err.max()),
            "max_abs_value": float(np.abs(ref).max()),
            "max_rel_error": float((err / np.maximum(np.abs(ref), 1e-6)).max()),
            "bit_identical": bool((ref == got).all()),
        }
    print(json.dumps(report, indent=2))


def spread(gpu, cpu):
    """How far Python's own GPU and CPU results are apart: the scale for E4's GPU error."""
    report = {}
    for name in STAGES:
        g = np.load(gpu / ("ref-%s.npy" % name)).astype(np.float64)
        c = np.load(cpu / ("ref-%s.npy" % name)).astype(np.float64)
        p = np.load(gpu / ("pop-%s.npy" % name)).astype(np.float64)
        report[name] = {
            "python_gpu_vs_python_cpu_max_abs": float(np.abs(g - c).max()),
            "pop11_gpu_vs_python_gpu_max_abs": float(np.abs(p - g).max()),
        }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
