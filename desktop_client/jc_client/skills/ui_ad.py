"""agent-desktop as a look/move engine for ``ui_look``/``ui_do`` (helpers only, no skills here).

``read`` turns an agent-desktop snapshot into today's look parts — numbered elements with roles
in today's AX names (so the server's choices and guards keep working), a frame, and the window
text — and ``act`` presses / fills / scrolls a ref, reporting whether the move ``landed`` from
agent-desktop's delivery evidence. Refs never leave jc-client; text typed never appears in a result.
"""
from __future__ import annotations

ROLE_MAP = {
    "button": "AXButton", "textfield": "AXTextField", "checkbox": "AXCheckBox", "link": "AXLink",
    "menuitem": "AXMenuItem", "tab": "AXRadioButton", "slider": "AXSlider", "combobox": "AXComboBox",
    "treeitem": "AXRow", "cell": "AXCell", "radiobutton": "AXRadioButton", "incrementor": "AXIncrementor",
    "menubutton": "AXMenuButton", "switch": "AXCheckBox", "colorwell": "AXColorWell", "dockitem": "AXDockItem",
    "listbox": "AXList", "option": "AXRow", "scrollarea": "AXScrollArea", "disclosure": "AXDisclosureTriangle",
}
_SNAPSHOT_MS = 5000
_CALL_S = 8.0
_STALE = "That screen changed; look again."


def _role(ad_role: str) -> str:
    return ROLE_MAP.get(ad_role) or "AX" + str(ad_role or "unknown").title()


def _pt(node: dict) -> tuple:
    b = node.get("bounds") or {}
    return (round(float(b.get("x") or 0)), round(float(b.get("y") or 0)),
            round(float(b.get("width") or 0)), round(float(b.get("height") or 0)))


def _label(node: dict) -> str:
    for key in ("name", "value", "description"):
        v = node.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def flatten(data: dict, max_elements: int = 400) -> tuple:
    """(elements, texts) from a snapshot's tree, depth first; menu items labelled with their path."""
    elements: list = []
    texts: list = []

    def walk(node: dict, path: list) -> None:
        role = str(node.get("role") or "")
        label = _label(node)
        if node.get("ref_id") and len(elements) < max_elements:
            if role == "menuitem" and not label:
                pass  # a separator
            else:
                shown = " › ".join([*path, label]) if role == "menuitem" and path else label
                elements.append({"role": _role(role), "label": shown, "pt": _pt(node), "kind": role,
                                 "adref": node["ref_id"]})
        elif not node.get("ref_id") and label and role != "menu":
            texts.append(label)
        inner = [*path, label] if role == "menuitem" and label else path
        for child in node.get("children") or []:
            if isinstance(child, dict):
                walk(child, inner)

    if isinstance(data.get("tree"), dict):
        walk(data["tree"], [])
    return elements, texts


def landed(envelope: dict) -> str:
    """"yes" (delivered and verified), "no" (provably not delivered), else "unknown"."""
    if envelope.get("ok"):
        disp = (envelope.get("data") or {}).get("disposition") or {}
        return "yes" if disp.get("delivery") == "delivered_verified" else "unknown"
    disp = (envelope.get("error") or {}).get("disposition") or {}
    return "no" if disp.get("delivery") == "not_delivered" else "unknown"


def _frame(data: dict, elements: list):
    b = ((data.get("window") or {}).get("bounds")) or None
    if b:
        return _pt({"bounds": b})
    root = _pt(data.get("tree") or {})
    if root[2] > 0 and root[3] > 0:
        return root  # a surface's own bounds (its items' boxes can be scattered)
    boxes =[e["pt"] for e in elements if e["pt"][2] > 0 and e["pt"][3] > 0]
    if not boxes:
        return None
    x0, y0 = min(p[0] for p in boxes), min(p[1] for p in boxes)
    x1, y1 = max(p[0] + p[2] for p in boxes), max(p[1] + p[3] for p in boxes)
    return (x0, y0, x1 - x0, y1 - y0)


def _error(envelope: dict) -> dict:
    err = envelope.get("error") or {}
    code, message = str(err.get("code") or "ERROR"), str(err.get("message") or "")
    if "RefMap" in message:
        code = "TOO_BIG"
    return {"ok": False, "code": code, "error": f"agent-desktop: {message or code}"}


def _notifications(client, headed_ok: bool) -> dict:
    # Notification Center must be opened to be read (agent-desktop puts the focus back after).
    envelope = (client.cli(["--headed", "list-notifications", "--limit", "10"], timeout=_CALL_S) if headed_ok
                else client.call("desktop_list_notifications", {"limit": 10}, timeout=_CALL_S))
    if not envelope or not envelope.get("ok"):
        return _error(envelope or {})
    items = envelope.get("data")
    items = items.get("notifications", []) if isinstance(items, dict) else items or []
    texts = []
    for item in items:
        if not isinstance(item, dict):
            continue
        app = str(item.get("app") or item.get("app_name") or "")
        title = str(item.get("title") or "")
        body = str(item.get("body") or item.get("subtitle") or item.get("message") or "")
        head = ": ".join(p for p in (app, title) if p)
        texts.append(" — ".join(p for p in (head, body) if p))
    return {"ok": True, "app": "Notification Center", "title": "Notification Center", "frame": None,
            "elements": [], "texts": texts, "snapshot_id": None}


def read(client, *, app, surface, max_elements: int = 400, headed_ok: bool = False) -> dict:
    """One look through agent-desktop, or ``{"ok": False, "code", "error"}`` (the caller falls back)."""
    if surface == "notifications":
        return _notifications(client, headed_ok)
    args: dict = {}
    if app:
        args["app"] = app
    if surface:
        args["surface"] = surface
    args.update(interactive_only=True, compact=True, include_bounds=True, timeout_ms=_SNAPSHOT_MS)
    envelope = client.call("desktop_snapshot", args, timeout=_CALL_S)
    if not envelope.get("ok"):
        return _error(envelope)
    data = envelope.get("data") or {}
    elements, texts = flatten(data, max_elements)
    title = str((data.get("window") or {}).get("title") or data.get("app") or app or surface or "")
    return {"ok": True, "app": data.get("app") or app, "title": title, "frame": _frame(data, elements),
            "elements": elements, "texts": texts, "snapshot_id": data.get("snapshot_id")}


def act(client, adref: str, action: str, *, text=None, direction=None, role: str = "") -> dict:
    """Click / fill / scroll one ref; ``{"ok", "did", "via", "landed"}`` or ``{"ok": False, "error", "landed"}``."""
    if action == "click":
        tool, args = "desktop_click", {"ref_id": adref}
    elif action == "fill":
        tool = "desktop_select" if role == "AXComboBox" else "desktop_set_value"
        args = {"ref_id": adref, "value": text or ""}
    elif action == "scroll":
        tool, args = "desktop_scroll", {"ref_id": adref, "direction": direction or "down", "amount": 3}
    else:
        return {"ok": False, "error": f"agent-desktop can't {action}", "landed": "no"}
    envelope = client.call(tool, args, timeout=_CALL_S)
    if envelope.get("ok"):
        return {"ok": True, "did": action, "via": "agent-desktop", "landed": landed(envelope)}
    err = envelope.get("error") or {}
    if err.get("code") == "STALE_REF":
        message = _STALE
    else:
        message = f"agent-desktop: {err.get('message') or err.get('code') or 'failed'}"
        if text:
            message = message.replace(text, "…")
    return {"ok": False, "error": message, "landed": landed(envelope)}
