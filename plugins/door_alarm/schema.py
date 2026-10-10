"""The hub's data points (DPs), parsed from Tuya's thing model, and what each one is for.

Smart Life's control page for the hub is a mini-app downloaded at runtime, so everything the hub can
do is its DP list. Roles (door, siren, volume, ringtone…) come from a per-product file in
``products/<product_id>.json`` when one exists, else from Tuya's standard code names.
"""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

PRODUCTS_DIR = Path(__file__).with_name("products")

ROLE_PATTERNS: list[tuple[str, re.Pattern]] = [
    # "^door" but not "doorbell_*" (a doorbell's volume or song is not a door sensor).
    ("door", re.compile(r"(doorcontact|door_contact|door_state|contact_state|^door(?!bell)|sensor_state)")),
    ("tamper", re.compile(r"(temper|tamper)")),
    ("battery", re.compile(r"(battery|bat_)")),
    ("ringtone", re.compile(r"(ringtone|ring_tone|alarm_ring|bell_tone|music|ring$|song)")),
    ("volume", re.compile(r"volume")),
    ("siren", re.compile(r"(alarm_switch|siren|^alarm$|alarm_sound|sound_switch|^ring_switch|alarm_state)")),
    ("siren_time", re.compile(r"(alarm_time|alarm_duration|ring_time|duration)")),
    ("mode", re.compile(r"mode")),
]
ROLES = [name for name, _ in ROLE_PATTERNS]

_SPEC_TYPES = {"boolean": "bool", "bool": "bool", "enum": "enum", "integer": "value", "value": "value",
               "string": "string", "json": "string", "raw": "raw", "bitmap": "bitmap"}


@dataclass
class Dp:
    id: int
    code: str
    name: str = ""
    type: str = "raw"            # bool | enum | value | string | raw | bitmap
    mode: str = "rw"             # rw | ro | wr
    range: list = field(default_factory=list)
    min: Optional[int] = None
    max: Optional[int] = None
    step: int = 1
    scale: int = 0
    unit: str = ""
    maxlen: Optional[int] = None
    labels: list = field(default_factory=list)

    @property
    def writable(self) -> bool:
        return self.mode in ("rw", "wr")

    def public(self) -> dict:
        out = asdict(self)
        out["writable"] = self.writable
        return out


def _dp_from_spec(dp_id: int, code: str, name: str, type_spec: dict, mode: str) -> Dp:
    kind = _SPEC_TYPES.get(str(type_spec.get("type", "raw")).lower(), "raw")
    dp = Dp(id=dp_id, code=code, name=name or code, type=kind, mode=mode if mode in ("rw", "ro", "wr") else "rw")
    if kind == "enum":
        dp.range = [str(v) for v in type_spec.get("range") or []]
    elif kind == "value":
        for attr in ("min", "max", "step", "scale"):
            if type_spec.get(attr) is not None:
                setattr(dp, attr, int(type_spec[attr]))
        dp.step = dp.step or 1
        dp.unit = str(type_spec.get("unit") or "")
    elif kind == "bitmap":
        dp.labels = list(type_spec.get("label") or [])
    if type_spec.get("maxlen") is not None:
        dp.maxlen = int(type_spec["maxlen"])
    return dp


def parse_model(model: dict) -> dict[int, Dp]:
    """``GET /v2.0/cloud/thing/{id}/model`` → DPs by id."""
    out: dict[int, Dp] = {}
    for service in (model or {}).get("services") or []:
        for prop in service.get("properties") or []:
            try:
                dp_id = int(prop["abilityId"])
            except (KeyError, TypeError, ValueError):
                continue
            out[dp_id] = _dp_from_spec(dp_id, str(prop.get("code") or dp_id), str(prop.get("name") or ""),
                                       prop.get("typeSpec") or {}, str(prop.get("accessMode") or "rw"))
    return dict(sorted(out.items()))


def parse_specifications(specs: dict) -> dict[int, Dp]:
    """``GET /v1.1/devices/{id}/specifications`` → DPs by id. A DP listed under ``functions`` is
    writable; one only under ``status`` is read-only."""
    writable = {int(f["dp_id"]) for f in (specs or {}).get("functions") or [] if "dp_id" in f}
    out: dict[int, Dp] = {}
    for entry in ((specs or {}).get("status") or []) + ((specs or {}).get("functions") or []):
        try:
            dp_id = int(entry["dp_id"])
        except (KeyError, TypeError, ValueError):
            continue
        if dp_id in out:
            continue
        values = entry.get("values") or "{}"
        try:
            spec = json.loads(values) if isinstance(values, str) else dict(values)
        except ValueError:
            spec = {}
        spec["type"] = entry.get("type", "raw")
        out[dp_id] = _dp_from_spec(dp_id, str(entry.get("code") or dp_id), str(entry.get("name") or ""),
                                   spec, "rw" if dp_id in writable else "ro")
    return dict(sorted(out.items()))


def product_file(product_id: Optional[str], products_dir: Path | None = None) -> dict:
    if not product_id or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", product_id):
        return {}
    path = (products_dir or PRODUCTS_DIR) / f"{product_id}.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def roles(dps: dict[int, Dp], product_id: Optional[str] = None, products_dir: Path | None = None) -> dict[str, list[str]]:
    """Role → DP codes. The product file wins per role; other roles keep the heuristic."""
    out: dict[str, list[str]] = {name: [] for name in ROLES}
    for dp in dps.values():
        code = dp.code.lower()
        for name, pattern in ROLE_PATTERNS:
            if pattern.search(code):
                out[name].append(dp.code)
                break
    for name, codes in (product_file(product_id, products_dir).get("roles") or {}).items():
        out[name] = [str(c) for c in codes or []]
    return out


def coerce(dp: Dp, value: Any) -> Any:
    """The value to send for ``dp``, or ValueError saying why it can't be set."""
    if not dp.writable:
        raise ValueError(f"'{dp.name or dp.code}' is read-only on the hub.")
    if dp.type == "bool":
        if isinstance(value, bool):
            return value
        if value in (0, 1):
            return bool(value)
        text = str(value).strip().lower()
        if text in ("true", "on", "yes", "1"):
            return True
        if text in ("false", "off", "no", "0"):
            return False
        raise ValueError(f"'{dp.name}' takes on/off, not {value!r}.")
    if dp.type == "enum":
        text = str(value)
        if text not in dp.range:
            raise ValueError(f"'{dp.name}' takes one of {', '.join(dp.range)}, not {value!r}.")
        return text
    if dp.type in ("value", "bitmap"):
        if isinstance(value, bool):
            raise ValueError(f"'{dp.name}' takes a number.")
        try:
            number = float(value)
        except (TypeError, ValueError):
            raise ValueError(f"'{dp.name}' takes a number, not {value!r}.") from None
        if number != int(number):
            raise ValueError(f"'{dp.name}' takes a whole number.")
        number = int(number)
        if dp.min is not None and number < dp.min or dp.max is not None and number > dp.max:
            raise ValueError(f"'{dp.name}' goes from {dp.min} to {dp.max}.")
        if dp.type == "value" and dp.step > 1 and (number - (dp.min or 0)) % dp.step:
            raise ValueError(f"'{dp.name}' moves in steps of {dp.step}.")
        return number
    text = str(value)
    if dp.maxlen is not None and len(text) > dp.maxlen * (2 if dp.type == "raw" else 1):
        raise ValueError(f"'{dp.name}' is too long.")
    return text
