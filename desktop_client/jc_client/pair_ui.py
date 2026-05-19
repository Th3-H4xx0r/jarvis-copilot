"""First-run pairing dialog.

Primary backend: **pywebview** — embeds a native system webview
(WebKit on macOS, WebView2 on Windows, WebKitGTK on Linux) and loads
inline HTML/CSS that mirrors the webui's /pair page. Dark theme,
gradient JC logo and CTA, modern form inputs.

Communication between the HTML and Python goes through pywebview's
``expose`` API — JS calls ``window.pywebview.api.try_pair(...)`` and
Python does the actual HTTPS call (so we keep our TLS-fingerprint
pinning + 0600 credential storage logic on the trusted side).

Fallback: when pywebview is unavailable (headless box, missing system
WebView runtime, etc.) we degrade to a small tkinter dialog so users
can still pair.

Public entry: ``show()`` runs the modal, returns the saved
Credentials (or None on cancel).
"""
from __future__ import annotations

import json
import logging
import socket
import sys
import threading
import time
import uuid
from typing import Optional

from jc_client import credentials
from jc_client.protocol import HttpClient

log = logging.getLogger(__name__)


# ── Modern HTML/CSS payload ────────────────────────────────────────────────
# Self-contained: no external assets, no internet round-trips. The colour
# palette is identical to webui/api/routes.py:_PAIR_PAGE_HTML so this
# dialog and the browser-side /pair page look like one app.

_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair this device</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-user-select:none;user-select:none}
input,textarea{-webkit-user-select:text;user-select:text}
html,body{height:100%}
body{background:#0e1626;color:#e8e8f0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;
  background:radial-gradient(ellipse at 30% 0%,rgba(240,179,65,.10),transparent 60%),
             radial-gradient(ellipse at 80% 100%,rgba(124,185,255,.06),transparent 60%),
             #0e1626}
.card{background:#14203a;border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:36px 32px;
  width:100%;max-width:420px;box-shadow:0 24px 80px rgba(0,0,0,.5);position:relative;overflow:hidden}
.card::before{content:"";position:absolute;inset:0 0 auto 0;height:2px;
  background:linear-gradient(90deg,transparent,#f0b341,#e0552b,transparent)}
.logo{width:64px;height:64px;border-radius:16px;background:linear-gradient(145deg,#f0b341,#e0552b);
  display:flex;align-items:center;justify-content:center;font-weight:800;font-size:24px;color:#fff;
  margin:0 auto 16px;box-shadow:0 8px 28px rgba(224,85,43,.4);letter-spacing:.5px}
h1{font-size:20px;font-weight:600;text-align:center;margin-bottom:6px}
.sub{font-size:13px;color:#9aa1bd;text-align:center;margin-bottom:22px;line-height:1.55}
label{display:block;font-size:11px;font-weight:600;color:#9aa1bd;
  letter-spacing:.08em;text-transform:uppercase;margin-top:14px;margin-bottom:7px}
input.field{width:100%;padding:11px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.10);
  background:rgba(255,255,255,.04);color:#e8e8f0;font-size:14px;outline:none;
  transition:border-color .15s,box-shadow .15s,background .15s}
input.field:focus{border-color:rgba(240,179,65,.55);box-shadow:0 0 0 3px rgba(240,179,65,.16);
  background:rgba(255,255,255,.06)}
.code-row{display:flex;gap:6px;justify-content:center;align-items:center}
.code-row input{width:38px;height:48px;text-align:center;font-size:22px;font-weight:700;
  letter-spacing:.5px;border-radius:10px;border:1px solid rgba(255,255,255,.12);
  background:rgba(255,255,255,.05);color:#e8e8f0;outline:none;text-transform:uppercase;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;transition:border-color .15s,box-shadow .15s}
.code-row input:focus{border-color:rgba(240,179,65,.55);box-shadow:0 0 0 3px rgba(240,179,65,.18)}
.dash{color:#5a637c;font-weight:700;padding:0 6px;font-size:20px}
button{width:100%;padding:13px;margin-top:22px;border-radius:11px;border:none;
  background:linear-gradient(145deg,#f0b341,#e0552b);color:#fff;font-size:14px;font-weight:700;
  cursor:pointer;transition:filter .15s,transform .05s,box-shadow .15s;letter-spacing:.3px;
  box-shadow:0 4px 16px rgba(224,85,43,.32)}
button:hover{filter:brightness(1.08);box-shadow:0 6px 22px rgba(224,85,43,.42)}
button:active{transform:translateY(1px)}
button[disabled]{filter:grayscale(.5) brightness(.6);cursor:not-allowed;box-shadow:none}
button.secondary{background:rgba(255,255,255,.06);color:#cdd3ec;
  box-shadow:none;border:1px solid rgba(255,255,255,.08);margin-top:8px}
button.secondary:hover{background:rgba(255,255,255,.10)}
.msg{margin-top:14px;font-size:13px;text-align:center;min-height:18px;line-height:1.5}
.msg.err{color:#ff8a8a}
.msg.ok{color:#7ae597}
.hint{margin-top:18px;font-size:11px;color:#6b7390;text-align:center;line-height:1.6}
.hint code{background:rgba(255,255,255,.06);padding:2px 6px;border-radius:5px;color:#cdd3ec;
  font-family:ui-monospace,Menlo,monospace;font-size:11px}
.spinner{display:inline-block;width:12px;height:12px;border:2px solid rgba(240,179,65,.4);
  border-top-color:#f0b341;border-radius:50%;animation:spin .7s linear infinite;
  vertical-align:-2px;margin-right:6px}
@keyframes spin{to{transform:rotate(360deg)}}
.fp-box{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.10);border-radius:10px;
  padding:14px;margin:14px 0;font-family:ui-monospace,Menlo,monospace;font-size:11.5px;
  letter-spacing:.5px;word-break:break-all;text-align:center;color:#cdd3ec;line-height:1.7}
.kv{font-size:12px;color:#9aa1bd;margin:4px 0;line-height:1.6}
.kv b{color:#e8e8f0;font-weight:600}
.checkmark{width:64px;height:64px;border-radius:50%;background:linear-gradient(145deg,#7ae597,#3aa66b);
  display:flex;align-items:center;justify-content:center;margin:8px auto 16px;
  box-shadow:0 8px 28px rgba(58,166,107,.4);font-size:32px;color:#fff;font-weight:800}
.screen{animation:slidein .35s ease}
@keyframes slidein{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}
</style></head><body>

<div class="card" id="card">
  <!-- Screen 1: form -->
  <div id="screen-form" class="screen">
    <div class="logo">JC</div>
    <h1>Pair this device</h1>
    <p class="sub">Connect this machine to a JarvisCopilot server.<br>
      Get a pairing code from <code>jarviscopilot pair</code> on the server.</p>

    <label for="server">Server URL</label>
    <input id="server" class="field" placeholder="https://192.168.1.10:8787" autocomplete="off" spellcheck="false">

    <label>Pairing code</label>
    <div class="code-row">
      <input class="c" id="c0" maxlength="1" autocapitalize="characters">
      <input class="c" id="c1" maxlength="1" autocapitalize="characters">
      <input class="c" id="c2" maxlength="1" autocapitalize="characters">
      <span class="dash">&minus;</span>
      <input class="c" id="c3" maxlength="1" autocapitalize="characters">
      <input class="c" id="c4" maxlength="1" autocapitalize="characters">
      <input class="c" id="c5" maxlength="1" autocapitalize="characters">
    </div>

    <label for="device">Device name</label>
    <input id="device" class="field" maxlength="48" autocomplete="off">

    <button id="submit">Pair</button>
    <button id="cancel" class="secondary">Cancel</button>
    <div id="msg" class="msg"></div>
  </div>

  <!-- Screen 2: fingerprint confirmation -->
  <div id="screen-fp" class="screen" style="display:none">
    <div class="logo">JC</div>
    <h1>Confirm server identity</h1>
    <p class="sub">The server presented this TLS cert fingerprint.<br>
      Verify it matches <code>jarviscopilot status</code> on the server.</p>
    <div class="fp-box" id="fp-display"></div>
    <div class="kv">Server <b id="fp-server"></b></div>
    <div class="kv">Device <b id="fp-device"></b></div>
    <button id="fp-confirm">Confirm &amp; save</button>
    <button id="fp-back" class="secondary">Back</button>
  </div>

  <!-- Screen 3: success -->
  <div id="screen-success" class="screen" style="display:none">
    <div class="checkmark">&check;</div>
    <h1>Paired</h1>
    <p class="sub" id="success-text"></p>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
const codeInputs = [...document.querySelectorAll('.c')];

// Default device name comes from Python via a tiny init call.
window.addEventListener('pywebviewready', async () => {
  try {
    const defaults = await window.pywebview.api.defaults();
    $('device').value = defaults.device_name || '';
    $('server').value = defaults.server_url || 'https://';
    if (defaults.server_url) $('c0').focus(); else $('server').focus();
  } catch (e) { /* dialog already loaded */ }
});

// Auto-advance + uppercase on the code boxes.
codeInputs.forEach((el, i) => {
  el.addEventListener('input', () => {
    el.value = el.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (el.value && i < codeInputs.length - 1) codeInputs[i + 1].focus();
  });
  el.addEventListener('keydown', ev => {
    if (ev.key === 'Backspace' && !el.value && i > 0) codeInputs[i - 1].focus();
  });
  el.addEventListener('paste', ev => {
    const txt = (ev.clipboardData || window.clipboardData).getData('text') || '';
    const cleaned = txt.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
    if (cleaned.length) {
      ev.preventDefault();
      for (let k = 0; k < 6; k++) codeInputs[k].value = cleaned[k] || '';
      codeInputs[Math.min(cleaned.length, 5)].focus();
    }
  });
});

let pendingCookie = null;
let pendingFingerprint = null;

$('submit').addEventListener('click', async () => {
  const server = $('server').value.trim();
  const code = codeInputs.map(e => e.value).join('');
  const device = $('device').value.trim();
  const msg = $('msg');

  if (!server || server.indexOf('://') < 0) {
    msg.className = 'msg err';
    msg.textContent = 'Enter the server URL (with https://).';
    return;
  }
  if (code.length !== 6) {
    msg.className = 'msg err';
    msg.textContent = 'Pairing code must be 6 characters.';
    return;
  }

  $('submit').disabled = true;
  msg.className = 'msg';
  msg.innerHTML = '<span class="spinner"></span>Contacting server…';

  try {
    const result = await window.pywebview.api.try_pair(server, code, device);
    if (result.ok) {
      pendingCookie = result.cookie;
      pendingFingerprint = result.fingerprint;
      // Pretty fingerprint: AB:CD:EF:… 16 pairs per line via word-break.
      const pretty = result.fingerprint.match(/.{1,2}/g).join(':').toUpperCase();
      $('fp-display').textContent = pretty;
      $('fp-server').textContent = server;
      $('fp-device').textContent = device || '(hostname)';
      $('screen-form').style.display = 'none';
      $('screen-fp').style.display = 'block';
      $('screen-fp').classList.remove('screen'); // re-trigger animation
      void $('screen-fp').offsetWidth;
      $('screen-fp').classList.add('screen');
    } else {
      $('submit').disabled = false;
      msg.className = 'msg err';
      msg.textContent = result.error || 'Pairing failed.';
    }
  } catch (e) {
    $('submit').disabled = false;
    msg.className = 'msg err';
    msg.textContent = 'Bridge error: ' + e;
  }
});

$('cancel').addEventListener('click', () => window.pywebview.api.cancel());

$('fp-back').addEventListener('click', () => {
  $('screen-fp').style.display = 'none';
  $('screen-form').style.display = 'block';
  $('submit').disabled = false;
  $('msg').textContent = '';
});

$('fp-confirm').addEventListener('click', async () => {
  const server = $('server').value.trim();
  const device = $('device').value.trim();
  await window.pywebview.api.confirm_and_save(
    server, device, pendingCookie, pendingFingerprint
  );
  $('success-text').textContent = 'Connected to ' + server + '. Closing…';
  $('screen-fp').style.display = 'none';
  $('screen-success').style.display = 'block';
  setTimeout(() => window.pywebview.api.cancel(), 1500);
});

// Enter triggers Pair from anywhere in the form.
document.addEventListener('keydown', ev => {
  if (ev.key === 'Enter' && $('screen-form').style.display !== 'none') {
    $('submit').click();
  }
  if (ev.key === 'Escape') {
    window.pywebview.api.cancel();
  }
});
</script>
</body></html>
"""


# ── pywebview API exposed to JS ────────────────────────────────────────────


class _PairAPI:
    """Methods on this class become callable from JS as
    ``window.pywebview.api.<method>(args…)``. Each returns JSON-able.

    The whole class is the trusted-Python side of the bridge: only the
    methods listed here can be invoked by the HTML page.
    """

    def __init__(self) -> None:
        self.window = None  # set by show()
        self.result: Optional[credentials.Credentials] = None

    def defaults(self) -> dict:
        """Initial values for the form fields. Called on page ready."""
        creds = credentials.load()
        return {
            "server_url": creds.server_url or "",
            "device_name": creds.device_name or socket.gethostname(),
        }

    def try_pair(self, server_url: str, code: str, device_name: str) -> dict:
        """Step 1 of pairing: claim the code, capture the cert fingerprint.

        Returns ``{ok, fingerprint, cookie}`` on success or
        ``{ok:false, error}`` on failure. Credentials are NOT persisted
        yet — that waits for ``confirm_and_save``.
        """
        url = _normalize_url(server_url)
        code = _normalize_code(code)
        try:
            client = HttpClient(url, expected_fingerprint="")
            resp, fingerprint = client.post_json(
                "/api/auth/pair/claim",
                {"code": code, "name": device_name or socket.gethostname()},
            )
        except Exception as exc:
            log.exception("pair claim raised")
            return {"ok": False, "error": _friendly_err(exc)}

        if resp.status != 200 or not resp.cookie:
            err = (resp.json().get("error") if resp.body else "") or f"HTTP {resp.status}"
            return {"ok": False, "error": str(err)}

        return {"ok": True, "fingerprint": fingerprint, "cookie": resp.cookie}

    def confirm_and_save(
        self, server_url: str, device_name: str, cookie: str, fingerprint: str
    ) -> dict:
        """Step 2: user confirmed the fingerprint. Persist creds."""
        creds = credentials.load()
        creds.server_url = _normalize_url(server_url)
        creds.device_name = (device_name or "").strip() or socket.gethostname()
        creds.cookie = cookie
        creds.cert_fingerprint = fingerprint
        if not creds.device_id:
            creds.device_id = uuid.uuid4().hex
        credentials.save(creds)
        self.result = creds
        log.info("paired with %s as %s", creds.server_url, creds.device_name)
        return {"ok": True}

    def cancel(self) -> dict:
        """Either Cancel button or success-screen auto-close. Both close
        the window; the result-or-None decision was made earlier."""
        try:
            if self.window:
                self.window.destroy()
        except Exception:
            pass
        return {"ok": True}


# ── Helpers ────────────────────────────────────────────────────────────────


def _normalize_url(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return s
    if "://" not in s:
        s = "https://" + s
    return s.rstrip("/")


def _normalize_code(raw: str) -> str:
    return "".join(ch for ch in (raw or "") if ch.isalnum()).upper()


def _friendly_err(exc: Exception) -> str:
    msg = str(exc)
    low = msg.lower()
    if "fingerprint mismatch" in low:
        return "TLS cert fingerprint mismatch. Did the server rotate its cert?"
    if "timed out" in low or "timeout" in low:
        return "Connection timed out. Is the server URL reachable from this machine?"
    if "name or service not known" in low or "no address" in low or "nodename" in low:
        return "Hostname lookup failed."
    if "ssl" in low or "certificate" in low:
        return f"TLS error: {msg}"
    if "refused" in low:
        return "Connection refused. Is the server running on that port?"
    return msg


# ── Backends ───────────────────────────────────────────────────────────────


def _show_webview() -> Optional[credentials.Credentials]:
    """Open the pywebview window. Returns the saved creds or None."""
    import webview  # type: ignore

    api = _PairAPI()
    window = webview.create_window(
        title="JarvisCopilot — Pair this device",
        html=_HTML,
        js_api=api,
        width=480,
        height=620,
        resizable=False,
        on_top=False,
        background_color="#0e1626",
        frameless=False,
        easy_drag=False,
    )
    api.window = window

    # webview.start() blocks until all windows are destroyed. The "private"
    # GUI flag picks the best backend per OS (Cocoa/Edge/QT/GTK).
    webview.start(debug=False)
    return api.result


def _show_tk_fallback() -> Optional[credentials.Credentials]:
    """Plain-Tk dialog used when pywebview can't initialise.

    Visually plainer but functionally identical: server URL + 6-char
    code + device name → pair → fingerprint confirmation → save.
    """
    import tkinter as tk
    from tkinter import messagebox, ttk

    result_holder: dict = {"creds": None}

    root = tk.Tk()
    root.title("JarvisCopilot — Pair this device")
    root.geometry("440x440")
    root.resizable(False, False)
    # Best-effort dark-ish theme on systems that honour ttk styling.
    try:
        style = ttk.Style(root)
        style.theme_use("clam")
    except Exception:
        pass

    outer = ttk.Frame(root, padding=20)
    outer.pack(fill="both", expand=True)
    ttk.Label(outer, text="Pair this device", font=("TkDefaultFont", 16, "bold")).pack(anchor="w")
    ttk.Label(
        outer,
        text="Connect this machine to a JarvisCopilot server.",
        foreground="#666",
    ).pack(anchor="w", pady=(0, 14))

    ttk.Label(outer, text="Server URL").pack(anchor="w")
    url_var = tk.StringVar(value=credentials.load().server_url or "https://")
    ttk.Entry(outer, textvariable=url_var, width=44).pack(anchor="w", fill="x", pady=(2, 10))

    ttk.Label(outer, text="Pairing code (XXX-XXX)").pack(anchor="w")
    code_var = tk.StringVar()

    def _on_code(*_a):
        cur = code_var.get()
        cleaned = "".join(ch for ch in cur if ch.isalnum()).upper()
        if len(cleaned) == 6:
            cleaned = cleaned[:3] + "-" + cleaned[3:]
        if cleaned != cur:
            code_var.set(cleaned)

    code_var.trace_add("write", _on_code)
    ttk.Entry(outer, textvariable=code_var, width=20).pack(anchor="w", pady=(2, 10))

    ttk.Label(outer, text="Device name").pack(anchor="w")
    name_var = tk.StringVar(value=credentials.load().device_name or socket.gethostname())
    ttk.Entry(outer, textvariable=name_var, width=44).pack(anchor="w", fill="x", pady=(2, 14))

    status_var = tk.StringVar()
    ttk.Label(outer, textvariable=status_var, foreground="#666").pack(anchor="w")

    api = _PairAPI()

    def _submit():
        url = url_var.get().strip()
        code = code_var.get().replace("-", "")
        device = name_var.get().strip() or socket.gethostname()
        if not url or "://" not in url or len(code) != 6:
            messagebox.showerror("Invalid input", "Enter a full URL and a 6-char code.")
            return
        status_var.set("Contacting server…")
        root.update_idletasks()
        res = api.try_pair(url, code, device)
        if not res.get("ok"):
            messagebox.showerror("Pair failed", res.get("error", "unknown"))
            status_var.set("")
            return
        fp = res["fingerprint"]
        pretty = ":".join(fp[i : i + 2].upper() for i in range(0, len(fp), 2))
        if not messagebox.askyesno(
            "Confirm server identity",
            f"Server fingerprint (SHA-256):\n\n{pretty}\n\n"
            "Verify this matches `jarviscopilot status` on the server. Confirm?",
        ):
            status_var.set("")
            return
        api.confirm_and_save(url, device, res["cookie"], fp)
        result_holder["creds"] = api.result
        messagebox.showinfo("Paired", f"Successfully paired with {url}.")
        root.destroy()

    btn_row = ttk.Frame(outer)
    btn_row.pack(fill="x", pady=(18, 0))
    ttk.Button(btn_row, text="Cancel", command=root.destroy).pack(side="right", padx=(8, 0))
    ttk.Button(btn_row, text="Pair", command=_submit).pack(side="right")

    root.bind("<Return>", lambda _e: _submit())
    root.bind("<Escape>", lambda _e: root.destroy())
    root.mainloop()
    return result_holder["creds"]


# ── Public entry ───────────────────────────────────────────────────────────


def show() -> Optional[credentials.Credentials]:
    """Open the pairing dialog. Returns saved credentials or None.

    Tries pywebview first (modern dark theme matching the webui).
    Falls back to tkinter if pywebview can't initialize — typically
    means a missing system WebView runtime (no WebKitGTK, no WebView2).
    """
    try:
        import webview  # type: ignore  # noqa: F401
        return _show_webview()
    except ImportError:
        log.info("pywebview not installed; using Tk fallback")
    except Exception as exc:
        log.warning("pywebview failed to start (%s); using Tk fallback", exc)

    try:
        return _show_tk_fallback()
    except Exception as exc:
        raise RuntimeError(
            "Pairing UI failed to start. Use the headless flow: "
            "`jc-client pair --server URL --code XXX-XXX --name NAME`"
        ) from exc
