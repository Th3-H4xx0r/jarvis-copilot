"""Tests for CodingTermManager (PTY relay).

Pure: no real tmux/claude — we exec tiny POSIX programs (`/bin/sh`, `cat`) in
the PTY and assert on the frames the manager pushes back through a fake `send`.
The Windows (pywinpty) path is skipped unless running on win32.

Run with::

    cd desktop_client && python -m pytest jc_client/test_coding_term.py -v
    # or, without pytest:
    cd desktop_client && python -m unittest jc_client.test_coding_term -v
"""

from __future__ import annotations

import sys
import threading
import time
import unittest

from jc_client.coding_term import CodingTermManager

POSIX_ONLY = unittest.skipIf(sys.platform == "win32",
                             "POSIX PTY test; Windows path needs pywinpty")


class _Recorder:
    """A thread-safe fake `send` that records every frame the manager emits."""

    def __init__(self) -> None:
        self.frames: list[dict] = []
        self._lock = threading.Lock()

    def __call__(self, frame: dict) -> None:
        with self._lock:
            self.frames.append(dict(frame))

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self.frames)

    def of_type(self, ftype: str) -> list[dict]:
        return [f for f in self.snapshot() if f.get("type") == ftype]

    def output_text(self, term_id: str) -> str:
        return "".join(
            f.get("data", "")
            for f in self.of_type("coding_term_output")
            if f.get("term_id") == term_id
        )


def _wait_until(pred, timeout: float = 3.0, interval: float = 0.01) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return False


@POSIX_ONLY
class TestCodingTermPosix(unittest.TestCase):

    def setUp(self) -> None:
        self.rec = _Recorder()
        self.mgr = CodingTermManager(send=self.rec)

    def tearDown(self) -> None:
        self.mgr.shutdown_all()

    def test_open_streams_output_then_exits(self):
        """A short-lived child produces output frames then a clean exit."""
        tid = "t-output"
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "cwd": None,
            "argv": ["/bin/sh", "-c", "printf hi; sleep 0.1"],
            "env": {},
        })
        # Eventually we see the exit frame…
        self.assertTrue(
            _wait_until(lambda: self.rec.of_type("coding_term_exit")),
            "no coding_term_exit frame",
        )
        # …and the output carried "hi".
        self.assertIn("hi", self.rec.output_text(tid))
        exits = self.rec.of_type("coding_term_exit")
        self.assertEqual(exits[0]["term_id"], tid)
        self.assertEqual(exits[0]["code"], 0)

    def test_reopen_replaces_existing_pty(self):
        """A second coding_term_open for the SAME term_id REPLACES the PTY. The old
        bug silently ignored the re-open, leaving the web 'reopen terminal' action
        permanently dead. The replaced PTY is closed WITHOUT a spurious exit frame;
        the new PTY actually runs."""
        tid = "t-reopen"
        # First PTY: a long-lived `cat`.
        self.mgr.handle_frame({"type": "coding_term_open", "term_id": tid,
                               "argv": ["cat"], "env": {}})
        time.sleep(0.15)  # let the first PTY come up
        # Re-open the SAME term_id with a DIFFERENT program.
        self.mgr.handle_frame({
            "type": "coding_term_open", "term_id": tid,
            "argv": ["/bin/sh", "-c", "printf SECOND; sleep 0.3"], "env": {}})
        # The new PTY ran (old behavior would have ignored the re-open → no SECOND).
        self.assertTrue(
            _wait_until(lambda: "SECOND" in self.rec.output_text(tid)),
            f"re-open did not start a new PTY; got {self.rec.output_text(tid)!r}",
        )
        # Exactly ONE exit frame — the SECOND program's clean exit. The replaced
        # first PTY's teardown is suppressed (closing=True), and its reader must
        # NOT have evicted the new term from the registry.
        self.assertTrue(_wait_until(
            lambda: [f for f in self.rec.of_type("coding_term_exit")
                     if f.get("term_id") == tid]))
        time.sleep(0.1)
        exits = [f for f in self.rec.of_type("coding_term_exit")
                 if f.get("term_id") == tid]
        self.assertEqual(len(exits), 1, f"expected exactly 1 exit, got {exits}")
        self.assertEqual(exits[0]["code"], 0)

    def test_input_is_echoed_back_as_output(self):
        """`cat` echoes stdin → we see our bytes come back as output frames."""
        tid = "t-cat"
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "argv": ["cat"],
            "env": {},
        })
        # Give the PTY a moment to come up, then write a line.
        time.sleep(0.1)
        self.mgr.handle_frame({
            "type": "coding_term_input",
            "term_id": tid,
            "data": "ping-123\n",
        })
        self.assertTrue(
            _wait_until(lambda: "ping-123" in self.rec.output_text(tid)),
            f"echo not observed; got {self.rec.output_text(tid)!r}",
        )
        # cat is still alive — no exit yet.
        self.assertEqual(self.rec.of_type("coding_term_exit"), [])

    def test_close_terminates_and_no_late_exit_frame(self):
        """Closing a long-lived child tears it down; a caller-initiated close
        suppresses the exit frame (the server asked for it)."""
        tid = "t-close"
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "argv": ["cat"],
            "env": {},
        })
        time.sleep(0.1)
        self.mgr.handle_frame({"type": "coding_term_close", "term_id": tid})
        # Reader thread should wind down (EOF after close).
        self.assertTrue(
            _wait_until(lambda: not _term_threads_alive(tid), timeout=3.0),
            "reader thread did not exit after close",
        )
        # No exit frame for a close WE initiated.
        late = [f for f in self.rec.of_type("coding_term_exit")
                if f.get("term_id") == tid]
        self.assertEqual(late, [], f"unexpected exit frame after close: {late}")

    def test_resize_does_not_crash_and_is_visible(self):
        """Resize is delivered to the PTY; the child observes the new size."""
        tid = "t-resize"
        # `stty size` prints "<rows> <cols>" for the controlling terminal.
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "argv": ["/bin/sh", "-c", "sleep 0.15; stty size"],
            "rows": 24,
            "cols": 80,
            "env": {},
        })
        # Resize before the child reads its size.
        time.sleep(0.05)
        self.mgr.handle_frame({
            "type": "coding_term_resize",
            "term_id": tid,
            "rows": 50,
            "cols": 100,
        })
        self.assertTrue(
            _wait_until(lambda: self.rec.of_type("coding_term_exit")),
            "child never exited",
        )
        out = self.rec.output_text(tid)
        # stty reports rows cols; the resize should have taken effect.
        self.assertIn("50", out, f"resized rows not seen in {out!r}")
        self.assertIn("100", out, f"resized cols not seen in {out!r}")

    def test_bad_argv_emits_exit_not_crash(self):
        """A non-existent program yields an exit frame with an error, not a raise."""
        tid = "t-bad"
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "argv": ["/no/such/binary-xyz"],
            "env": {},
        })
        self.assertTrue(
            _wait_until(lambda: any(
                f.get("term_id") == tid for f in self.rec.of_type("coding_term_exit")
            )),
            "no exit frame for bad argv",
        )
        exit_frame = next(f for f in self.rec.of_type("coding_term_exit")
                          if f.get("term_id") == tid)
        self.assertIn("error", exit_frame)
        self.assertNotEqual(exit_frame["code"], 0)

    def test_empty_argv_emits_exit(self):
        tid = "t-empty"
        self.mgr.handle_frame({
            "type": "coding_term_open",
            "term_id": tid,
            "argv": [],
        })
        self.assertTrue(
            _wait_until(lambda: any(
                f.get("term_id") == tid for f in self.rec.of_type("coding_term_exit")
            )),
            "no exit frame for empty argv",
        )

    def test_handle_frame_never_raises_on_junk(self):
        """Defensive: malformed frames are swallowed, not propagated."""
        for junk in (None, {}, {"type": "coding_term_open"},
                     {"type": "coding_term_input", "term_id": "nope", "data": "x"},
                     {"type": "unknown"}, "not-a-dict"):
            self.mgr.handle_frame(junk)  # type: ignore[arg-type]
        # Nothing blew up; no terminals were created from junk.
        opens = self.rec.of_type("coding_term_output")
        self.assertEqual(opens, [])


def _term_threads_alive(term_id: str) -> bool:
    prefix = f"coding-term-{term_id[:8]}"
    return any(t.is_alive() and t.name == prefix for t in threading.enumerate())


if __name__ == "__main__":
    unittest.main()
