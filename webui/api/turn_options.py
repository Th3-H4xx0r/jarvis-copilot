"""What the caller that starts one agent turn decides about it (chat, voice, a harness job).

Passed with the turn to api/streaming.py rather than left on the shared Session for the
streaming thread to find, so nothing from one turn can leak into the next.
"""
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass(frozen=True)
class TurnOptions:
    # "chat" | "voice": which surface's default harness answers (api/harness_runner.py).
    surface: str = "chat"
    # A harness the client named for this turn; None follows the chat's own, else the default.
    harness_id: Optional[str] = None
    # (model, provider) an older client picked: runs as Single with exactly that model.
    explicit_model: Optional[tuple] = None
    # A background harness node's hidden turn: its own model, tools and instructions.
    node: Optional[dict] = None
    # No extended thinking for this call (voice: every reasoning summary is silence).
    reasoning_off: bool = False
    # Notes for the model on this call only (voice reply rules, the sending device). They
    # ride the API copy of the user message: the system prompt stays cache-stable and the
    # saved message stays what the user said.
    context: str = ""
    # Cleans the turn's messages before they are saved (voice drops the Pod's "[end]").
    clean_messages: Optional[Callable[[list], None]] = None
