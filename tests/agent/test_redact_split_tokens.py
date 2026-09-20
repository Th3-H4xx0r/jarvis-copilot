"""A secret must not survive redaction by being broken up.

Two shapes got through: an invisible character in the middle of the token
(``sk-ab<ESC>cdef...``) split it so the matcher saw nothing, and a
dot-segmented key (Alibaba ``sk-sp-x.y``) ended at the dot. Both printed the
key in full into terminal output, a log line or a phone notification.
"""

import pytest

from agent.redact import redact_sensitive_text

SECRET_BODY = "abcdef1234567890"


def _leaked(text: str) -> bool:
    """True when a recognizable run of the secret survived unmasked."""
    return SECRET_BODY in redact_sensitive_text(text, force=True)


class TestInvisibleCharactersDoNotSplitASecret:
    @pytest.mark.parametrize(
        "sep",
        ["\x1b", "\x00", "\x07", "\x7f", "​", "‎", "⁠", "﻿"],
    )
    def test_secret_split_by_an_invisible_char_is_still_masked(self, sep):
        text = f"token sk-ab{sep}cdef1234567890 end"
        assert not _leaked(text), f"leaked with separator {sep!r}"

    def test_masked_output_keeps_the_surrounding_text(self):
        out = redact_sensitive_text("before sk-ab\x1bcdef1234567890 after", force=True)
        assert out.startswith("before ")
        assert out.rstrip().endswith("after")

    def test_two_split_secrets_in_one_string(self):
        text = "a sk-ab\x1bcdef1234567890 b sk-cd​ef1234567890abc c"
        out = redact_sensitive_text(text, force=True)
        assert SECRET_BODY not in out
        assert "a " in out and " c" in out


class TestDotSegmentedKeys:
    def test_alibaba_style_key_is_masked_through_the_dot(self):
        assert not _leaked("alibaba sk-sp-abcdef.gh1234567890")

    def test_plain_key_still_masked(self):
        assert not _leaked("token sk-abcdef1234567890")


class TestNoNewFalsePositives:
    @pytest.mark.parametrize(
        "text",
        [
            "just some ordinary prose here",
            "a line\twith a tab and a\nnewline",
            "version sk-1",                      # too short to be a key
            "the word sky is not a secret",
        ],
    )
    def test_benign_text_is_untouched(self, text):
        assert redact_sensitive_text(text, force=True) == text

    def test_tabs_and_newlines_are_not_folded_away(self):
        """Folding real separators would glue unrelated words into one token."""
        text = "alpha\tbeta\ngamma"
        assert redact_sensitive_text(text, force=True) == text
