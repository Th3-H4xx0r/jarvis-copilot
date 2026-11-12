"""jc_client.skills.common.notify — server-controlled text never reaches a script."""
import jc_client.skills.common as common


def test_notify_darwin_passes_untrusted_text_as_argv_not_script(monkeypatch):
    """SECURITY: title/message (server-controlled) must reach osascript as
    ARGUMENTS bound to `on run {t, m}`, never interpolated into the -e script
    source — so a `do shell script` / quote / backslash payload can't be
    executed or break out."""
    calls = []
    monkeypatch.setattr(common.sys, "platform", "darwin")
    monkeypatch.setattr(common.subprocess, "run",
                        lambda argv, **kw: calls.append(argv) or None)
    payload = '" & (do shell script "touch /tmp/PWNED") & "'
    common.notify(title='Evil"Title', message=payload)
    assert calls, "osascript was not invoked"
    argv = calls[0]
    assert argv[0] == "osascript" and argv[1] == "-e"
    script = argv[2]
    # The script is a fixed `on run {t, m}` wrapper; the untrusted text is NOT in it.
    assert "on run" in script and "display notification m with title t" in script
    assert "do shell script" not in script and "Evil" not in script
    # title + message are the trailing args, passed verbatim (no quote-mangling).
    assert argv[-2] == 'Evil"Title'
    assert argv[-1] == payload
