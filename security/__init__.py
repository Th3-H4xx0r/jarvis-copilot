"""Security utilities ported from openhuman (paths, commands, SSRF, prompt-injection).

These are dependency-light, pure-Python helpers. The path/command helpers are a
library callers opt into (a coding agent legitimately edits files broadly, so
containment is deliberately not a blanket default); the credential/system
denylist, the SSRF guard, and the indirect-injection screener are safe to wire
into the relevant tool paths.
"""
from .paths import is_forbidden_path, is_within, validate_path
from .commands import classify_command, gate_decision, has_hidden_execution, is_high_risk
from .injection import scan, screen_untrusted, verdict

# NB: SSRF/private-IP blocking already lives in tools/url_safety.py (mature:
# metadata-endpoint blocks, redirect re-validation, config toggle), so this
# package deliberately does not ship a second SSRF guard.

__all__ = [
    "is_forbidden_path", "is_within", "validate_path",
    "classify_command", "gate_decision", "has_hidden_execution", "is_high_risk",
    "scan", "screen_untrusted", "verdict",
]
