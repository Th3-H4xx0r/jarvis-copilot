"""An image result must reach the agent as an envelope, not as JSON text.

`_coerce_result` turned every dict into a JSON string (to stop bare dicts 400-ing
providers), which also stringified the `{"_multimodal": True, ...}` envelopes, so
screenshots reached the model as base64 text instead of image parts."""
import json

from tools.registry import _coerce_result


def test_multimodal_envelope_passes_through():
    env = {"_multimodal": True, "text_summary": "s",
           "content": [{"type": "text", "text": "s"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}]}
    assert _coerce_result("computer_do", env) is env


def test_plain_dicts_are_still_json_strings():
    assert json.loads(_coerce_result("x", {"ok": True})) == {"ok": True}
    assert _coerce_result("x", {"_multimodal": True, "content": "not a list"}) != {"_multimodal": True}
