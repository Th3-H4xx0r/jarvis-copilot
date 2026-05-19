"""First-run pairing dialog.

Single Tk window with three fields (server URL, code, device name)
plus a fingerprint-confirmation step before persisting credentials.

Flow:
    1. User types server URL + 6-char code (XXX-XXX) + device name.
    2. Submit → HttpClient hits the server with no pinning, capturing
       the observed TLS fingerprint along the way.
    3. UI shows the fingerprint + asks the user to confirm it matches
       what `jarviscopilot status` reports on the server. Confirm →
       creds saved and `Done` window closes.
    4. Cancel from the fingerprint step rolls back: credentials never
       hit disk.

Designed to be launched standalone (``python -m jc_client pair``) or
embedded — ``show(on_done=...)`` runs the mainloop and calls back
with the saved Credentials.
"""
from __future__ import annotations

import logging
import socket
import threading
import tkinter as tk
import tkinter.font as tkfont
import uuid
from tkinter import messagebox, ttk
from typing import Callable, Optional

from jc_client import credentials
from jc_client.protocol import HttpClient, HttpResponse

log = logging.getLogger(__name__)


# ── Validators ─────────────────────────────────────────────────────────────


def _normalize_code(raw: str) -> str:
    """Strip spaces, uppercase, insert dash after 3 chars. Accepts
    'abc-def', 'ABC DEF', 'abcdef'."""
    cleaned = "".join(ch for ch in raw if ch.isalnum()).upper()
    if len(cleaned) == 6:
        return f"{cleaned[:3]}-{cleaned[3:]}"
    return cleaned


def _normalize_url(raw: str) -> str:
    """Add https:// if the user typed a bare host. Strip trailing slash."""
    s = (raw or "").strip()
    if not s:
        return s
    if "://" not in s:
        s = "https://" + s
    return s.rstrip("/")


# ── Dialog ─────────────────────────────────────────────────────────────────


class PairDialog:
    def __init__(self, on_done: Optional[Callable[[credentials.Credentials], None]] = None):
        self.on_done = on_done
        self.result: Optional[credentials.Credentials] = None

        self.root = tk.Tk()
        self.root.title("JarvisCopilot — Pair this device")
        self.root.geometry("440x420")
        self.root.resizable(False, False)
        try:
            # Pull keyboard focus to the front on macOS.
            self.root.after(50, lambda: self.root.focus_force())
        except Exception:
            pass

        # Try a slightly larger default font so the dialog isn't tiny on HiDPI.
        try:
            default_font = tkfont.nametofont("TkDefaultFont")
            default_font.configure(size=11)
        except Exception:
            pass

        self._build_form()

    # ── Layout ────────────────────────────────────────────────────────

    def _build_form(self) -> None:
        outer = ttk.Frame(self.root, padding=24)
        outer.pack(fill="both", expand=True)

        title = ttk.Label(outer, text="Pair this device", font=("TkDefaultFont", 18, "bold"))
        title.pack(anchor="w", pady=(0, 4))
        sub = ttk.Label(
            outer,
            text=(
                "Connect this Mac/PC to a JarvisCopilot server.\n"
                "Get a code by running `jarviscopilot pair` on the server."
            ),
            foreground="#666",
            justify="left",
        )
        sub.pack(anchor="w", pady=(0, 18))

        # Server URL
        ttk.Label(outer, text="Server URL").pack(anchor="w")
        self.url_var = tk.StringVar(value="https://")
        url_entry = ttk.Entry(outer, textvariable=self.url_var, width=44)
        url_entry.pack(anchor="w", fill="x", pady=(2, 12))
        url_entry.focus_set()

        # Pairing code
        ttk.Label(outer, text="Pairing code (XXX-XXX)").pack(anchor="w")
        self.code_var = tk.StringVar()

        def _on_code_change(*_a):
            cur = self.code_var.get()
            norm = _normalize_code(cur)
            if norm != cur:
                self.code_var.set(norm)

        self.code_var.trace_add("write", _on_code_change)
        code_entry = ttk.Entry(outer, textvariable=self.code_var, width=20, font=("TkFixedFont", 14))
        code_entry.pack(anchor="w", pady=(2, 12))

        # Device name
        ttk.Label(outer, text="Device name").pack(anchor="w")
        self.name_var = tk.StringVar(value=socket.gethostname())
        ttk.Entry(outer, textvariable=self.name_var, width=44).pack(
            anchor="w", fill="x", pady=(2, 12)
        )

        # Status
        self.status_var = tk.StringVar(value="")
        ttk.Label(outer, textvariable=self.status_var, foreground="#666").pack(
            anchor="w", pady=(8, 0)
        )

        # Buttons
        btn_row = ttk.Frame(outer)
        btn_row.pack(fill="x", side="bottom", pady=(16, 0))
        ttk.Button(btn_row, text="Cancel", command=self._cancel).pack(side="right", padx=(8, 0))
        self.submit_btn = ttk.Button(btn_row, text="Pair", command=self._submit)
        self.submit_btn.pack(side="right")
        self.root.bind("<Return>", lambda _e: self._submit())
        self.root.bind("<Escape>", lambda _e: self._cancel())

    # ── Actions ───────────────────────────────────────────────────────

    def _set_status(self, text: str, color: str = "#666") -> None:
        self.status_var.set(text)

    def _submit(self) -> None:
        url = _normalize_url(self.url_var.get())
        code = _normalize_code(self.code_var.get())
        name = (self.name_var.get() or "").strip() or socket.gethostname()

        if not url or "://" not in url:
            messagebox.showerror("Bad URL", "Enter the server URL (with https://).")
            return
        if len(code.replace("-", "")) != 6:
            messagebox.showerror("Bad code", "Pairing code must be 6 characters (XXX-XXX).")
            return

        self.submit_btn.configure(state="disabled")
        self._set_status("Contacting server…")
        # Run the network call off the UI thread so the dialog doesn't freeze.
        thread = threading.Thread(
            target=self._do_pair,
            args=(url, code, name),
            daemon=True,
        )
        thread.start()

    def _do_pair(self, url: str, code: str, name: str) -> None:
        try:
            client = HttpClient(url, expected_fingerprint="")  # no pinning yet
            response, fingerprint = client.post_json(
                "/api/auth/pair/claim",
                {"code": code, "name": name},
            )
        except Exception as exc:
            log.exception("pair failed")
            self.root.after(0, self._on_pair_error, str(exc))
            return

        if response.status != 200 or not response.cookie:
            err = response.json().get("error") if response.body else None
            err = err or f"server returned HTTP {response.status}"
            self.root.after(0, self._on_pair_error, err)
            return

        self.root.after(
            0,
            self._show_fingerprint_step,
            url,
            name,
            response.cookie,
            fingerprint,
        )

    def _on_pair_error(self, msg: str) -> None:
        self._set_status("")
        self.submit_btn.configure(state="normal")
        messagebox.showerror("Pairing failed", msg)

    def _show_fingerprint_step(self, url: str, name: str, cookie: str, fingerprint: str) -> None:
        """Replace the form contents with a fingerprint-confirmation panel."""
        for child in self.root.winfo_children():
            child.destroy()
        outer = ttk.Frame(self.root, padding=24)
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text="Confirm server identity", font=("TkDefaultFont", 18, "bold")).pack(
            anchor="w", pady=(0, 6)
        )
        ttk.Label(
            outer,
            text=(
                "The server presented this TLS certificate fingerprint.\n"
                "On the server, run `jarviscopilot status` and verify the\n"
                "SHA-256 cert fingerprint matches the value below."
            ),
            foreground="#666",
            justify="left",
        ).pack(anchor="w", pady=(0, 14))

        # Fingerprint shown in groups of 4 hex chars for readability.
        pretty = ":".join(
            fingerprint[i : i + 2].upper() for i in range(0, len(fingerprint), 2)
        )
        fp_box = tk.Text(outer, height=4, width=44, wrap="word", relief="solid", borderwidth=1)
        fp_box.insert("1.0", pretty)
        fp_box.configure(state="disabled", font=("TkFixedFont", 10))
        fp_box.pack(anchor="w", pady=(0, 14))

        ttk.Label(
            outer,
            text="Server: " + url,
            foreground="#888",
        ).pack(anchor="w")
        ttk.Label(outer, text="Device: " + name, foreground="#888").pack(anchor="w", pady=(0, 18))

        btn_row = ttk.Frame(outer)
        btn_row.pack(fill="x", side="bottom")
        ttk.Button(btn_row, text="Cancel", command=self._cancel).pack(side="right", padx=(8, 0))
        ttk.Button(
            btn_row,
            text="Confirm & save",
            command=lambda: self._finalize(url, name, cookie, fingerprint),
        ).pack(side="right")

    def _finalize(self, url: str, name: str, cookie: str, fingerprint: str) -> None:
        creds = credentials.load()
        creds.server_url = url
        creds.device_name = name
        creds.cookie = cookie
        creds.cert_fingerprint = fingerprint
        if not creds.device_id:
            creds.device_id = uuid.uuid4().hex
        credentials.save(creds)
        self.result = creds
        log.info("paired with %s as %s", url, name)
        messagebox.showinfo(
            "Paired",
            f"Successfully paired with {url}.\n"
            "The background service will connect now.",
        )
        if self.on_done:
            try:
                self.on_done(creds)
            except Exception:
                log.exception("pair on_done callback failed")
        self.root.destroy()

    def _cancel(self) -> None:
        self.result = None
        self.root.destroy()


def show(on_done: Optional[Callable[[credentials.Credentials], None]] = None) -> Optional[credentials.Credentials]:
    """Show the pairing dialog, run mainloop, return saved credentials
    (or None if the user cancelled).
    """
    try:
        dlg = PairDialog(on_done=on_done)
    except tk.TclError as exc:
        # No display available — headless terminal / SSH session.
        raise RuntimeError(
            "Pairing UI needs a display. Set DISPLAY, or use "
            "`jc-client pair --server URL --code XXX --name NAME` for the "
            "non-interactive flow."
        ) from exc
    dlg.root.mainloop()
    return dlg.result
