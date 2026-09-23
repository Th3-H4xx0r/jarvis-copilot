#!/usr/bin/env python3
"""Rebuild JarvisCopilot/Copilot/Live/WeSpeakerResNet34.mlpackage from the
server's own ONNX checkpoint, so the phone's voiceprints are the server's.

    python3.11 -m venv /tmp/vp && /tmp/vp/bin/pip install "torch==2.7.0" \
        "torchvision==0.22.0" onnx onnx2torch onnxruntime coremltools "numpy<2.3"
    /tmp/vp/bin/python scripts/convert-voiceprint-model.py voxceleb_resnet34_LM.onnx

The ONNX file is the one `webui/api/live_voiceprint.py` downloads (MODEL_URL,
26,530,309 bytes). coremltools 9 is tested against torch 2.7 — a newer torch
converts without complaint and is not what the parity below was measured on.

Two decisions, both measured:

* The statistics pooling counted frames with Shape -> Gather -> ReduceProd, and
  CoreML has no converter for ReduceProd. The count is recomputed from the data
  (a row of ones summed over time), which is the same number for every length
  and traces dynamically. Parity against onnxruntime afterwards: cosine 1.0 at
  158-1198 frames.
* FLOAT32 compute. fp16 matched on the Mac (0.99999) but produced non-finite
  vectors in the iOS simulator, and int8 weights drifted to 0.996-0.998 — these
  vectors land in the same voice database the server writes, so exact wins over
  12 MB.
"""
import sys

import numpy as np
import onnx
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert


def main(onnx_path: str, out_path: str) -> None:
    model = convert(onnx.load(onnx_path)).eval()
    graph = model.graph
    nodes = {n.name: n for n in graph.nodes}
    x, count = nodes["relu_87"], nodes["cast_97"]
    with graph.inserting_after(x):
        first = graph.call_function(torch.ops.aten.slice.Tensor, (x, 1, 0, 1))
    with graph.inserting_after(first):
        first = graph.call_function(torch.ops.aten.slice.Tensor, (first, 2, 0, 1))
    with graph.inserting_after(first):
        zero = graph.call_function(torch.mul, (first, 0.0))
    with graph.inserting_after(zero):
        ones = graph.call_function(torch.add, (zero, 1.0))
    with graph.inserting_after(ones):
        n = graph.call_function(torch.sum, (ones,), {"dim": -1})
    with graph.inserting_after(n):
        n = graph.call_function(torch.reshape, (n, (-1,)))
    count.replace_all_uses_with(n)
    for name in ("cast_97", "reduce_prod_93", "gather_92", "constant_91", "shape_90"):
        graph.erase_node(nodes[name])
    graph.lint()
    model.recompile()

    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(0)
    probes = [rng.standard_normal((1, t, 80)).astype(np.float32) for t in (158, 300, 1198)]
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.from_numpy(probes[1]))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="feats", dtype=np.float32,
                              shape=(1, ct.RangeDim(lower_bound=40, upper_bound=2000, default=300), 80))],
        outputs=[ct.TensorType(name="embs")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram")
    for probe in probes:
        want = session.run(None, {"feats": probe})[0][0]
        got = mlmodel.predict({"feats": probe})["embs"].reshape(-1)
        cosine = float(np.dot(want, got) / (np.linalg.norm(want) * np.linalg.norm(got)))
        print(f"{probe.shape[1]} frames: cosine vs onnxruntime {cosine:.6f}")
        assert cosine > 0.9999, "not the server's model any more"
    mlmodel.save(out_path)
    print("wrote", out_path)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2
         else "JarvisCopilot/Copilot/Live/WeSpeakerResNet34.mlpackage")
