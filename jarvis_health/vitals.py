"""Spot readings with a clock of their own: blood pressure, glucose, blood fats,
uric acid, body composition and ECG.

The HBand band measures these on demand (and the rings record blood pressure).
They travel on a day as `measurements` rows — `{type, time, outcome, value,
systolic, diastolic, celsius, extra}` — and only `outcome == "done"` rows are
real values. Everything here is canonical: mmHg, mmol/L, µmol/L, kg, %, kcal.

The reference ranges are the usual adult ones. A wrist band estimates these
optically, so every verdict is phrased as a wellness estimate and never as a
diagnosis.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date as Date, timedelta
from statistics import mean
from typing import Optional

from .metrics import parse_instant

DISCLAIMER = ("These are wellness estimates from a wrist band's optical sensor, not medical measurements "
              "or a diagnosis.")
#: The short form, appended to a sentence on a phone card.
NOTE = "A wrist-band estimate, not a diagnosis."


@dataclass(frozen=True)
class Vital:
    key: str
    title: str
    #: The measurement type the number comes from.
    type: str
    #: `systolic` / `value`, or a key of the row's `extra`.
    field: str
    #: How it is written: mmhg, glucose, cholesterol, triglycerides, uric_acid, number, percent, kg, kcal, bpm, ms, breaths.
    kind: str
    #: Plausible values; anything outside is a failed reading, not a result.
    low: float
    high: float
    #: The smallest change worth calling a trend.
    step: float


VITALS: dict[str, Vital] = {v.key: v for v in (
    Vital("blood_pressure", "Blood pressure", "blood_pressure", "systolic", "mmhg", 60, 260, 5),
    Vital("blood_glucose", "Blood glucose", "blood_glucose", "blood_glucose_mmol_l", "glucose", 1, 35, 0.3),
    Vital("uric_acid", "Uric acid", "blood_component", "uric_acid_umol_l", "uric_acid", 50, 1200, 25),
    Vital("cholesterol", "Total cholesterol", "blood_component", "cholesterol_mmol_l", "cholesterol", 0.5, 20, 0.3),
    Vital("triglycerides", "Triglycerides", "blood_component", "triglycerides_mmol_l", "triglycerides", 0.1, 20, 0.2),
    Vital("hdl", "HDL cholesterol", "blood_component", "hdl_mmol_l", "cholesterol", 0.1, 10, 0.1),
    Vital("ldl", "LDL cholesterol", "blood_component", "ldl_mmol_l", "cholesterol", 0.1, 15, 0.3),
    Vital("bmi", "BMI", "body_composition", "bmi", "number", 8, 80, 0.5),
    Vital("body_fat", "Body fat", "body_composition", "body_fat_percent", "percent", 1, 75, 1),
    Vital("muscle_mass", "Muscle mass", "body_composition", "muscle_mass_kg", "kg", 1, 200, 0.5),
    Vital("skeletal_muscle", "Skeletal muscle", "body_composition", "skeletal_muscle_percent", "percent", 1, 90, 1),
    Vital("body_water", "Body water", "body_composition", "body_water_percent", "percent", 10, 90, 1),
    Vital("bone_mass", "Bone mass", "body_composition", "bone_mass_kg", "kg", 0.2, 10, 0.2),
    Vital("protein", "Protein", "body_composition", "protein_percent", "percent", 1, 50, 0.5),
    Vital("bmr", "Basal metabolism", "body_composition", "basal_metabolism_kcal", "kcal", 300, 6000, 40),
    Vital("ecg", "ECG heart rate", "ecg", "value", "bpm", 25, 250, 4),
    Vital("ecg_hrv", "ECG HRV", "ecg", "hrv", "ms", 1, 400, 5),
    Vital("respiratory_rate", "Breathing rate", "ecg", "respiratory_rate", "breaths", 4, 60, 1),
    Vital("ecg_qtc", "ECG QTc", "ecg", "qtc_ms", "ms", 250, 700, 10),
)}

_ROW_FIELDS = ("value", "systolic", "diastolic", "celsius")


def _number(row: dict, field: str) -> Optional[float]:
    raw = row.get(field) if field in _ROW_FIELDS else (row.get("extra") or {}).get(field)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def readings(measurements: list) -> list[dict]:
    """Every kept value as `{metric, at, value}` (blood pressure also `diastolic`), oldest first.

    One row of the band's may carry several (a blood-component reading is five);
    the same reading twice — two syncs, two devices — counts once.
    """
    out, seen = [], set()
    for row in measurements or []:
        if not isinstance(row, dict) or row.get("outcome") != "done" or not row.get("time"):
            continue
        for vital in VITALS.values():
            if vital.type != row.get("type"):
                continue
            value = _number(row, vital.field)
            if value is None or not vital.low <= value <= vital.high:
                continue
            reading = {"metric": vital.key, "at": str(row["time"]), "value": round(value, 2)}
            if vital.key == "blood_pressure":
                diastolic = _number(row, "diastolic")
                if diastolic is None or not 30 <= diastolic <= 160 or diastolic >= value:
                    continue
                reading["diastolic"] = round(diastolic, 1)
            if (vital.key, reading["at"]) in seen:
                continue
            seen.add((vital.key, reading["at"]))
            out.append(reading)
    return sorted(out, key=lambda r: r["at"])


def merge_measurements(*lists: list) -> list[dict]:
    """Rows from several devices or syncs as one list, each reading once, oldest first."""
    out, seen = [], set()
    for rows in lists:
        for row in rows or []:
            if not isinstance(row, dict):
                continue
            key = (row.get("type"), row.get("time"), row.get("outcome"))
            if key in seen:
                continue
            seen.add(key)
            out.append(row)
    return sorted(out, key=lambda r: str(r.get("time") or ""))


def summary(measurements: list) -> dict:
    """One day's numbers per vital: mean, lowest, highest, latest, how many."""
    by: dict[str, list[dict]] = {}
    for r in readings(measurements):
        by.setdefault(r["metric"], []).append(r)
    out: dict = {}
    for key, rows in by.items():
        values = [r["value"] for r in rows]
        out[key] = round(mean(values), 2)
        out[f"{key}_min"] = min(values)
        out[f"{key}_max"] = max(values)
        out[f"{key}_latest"] = values[-1]
        out[f"{key}_count"] = len(values)
        if key == "blood_pressure":
            lows = [r["diastolic"] for r in rows]
            out["blood_pressure_diastolic"] = round(mean(lows), 1)
            out["blood_pressure_diastolic_max"] = max(lows)
            out["blood_pressure_diastolic_latest"] = lows[-1]
    return out


# ── how they are written ─────────────────────────────────────────────────────

def say(kind: str, value: float, units: Optional[dict] = None, diastolic: Optional[float] = None) -> str:
    """A value in the person's units: "121/78 mmHg", "5.6 mmol/L", "101 mg/dL"…"""
    units = units or {}
    mg = lambda key: units.get(key) == "mgdL"  # noqa: E731
    if kind == "mmhg":
        return f"{round(value)}/{round(diastolic)} mmHg" if diastolic is not None else f"{round(value)} mmHg"
    if kind == "glucose":
        return f"{value * 18.016:.0f} mg/dL" if mg("glucose_unit") else f"{value:.1f} mmol/L"
    if kind == "cholesterol":
        return f"{value * 38.67:.0f} mg/dL" if mg("blood_fat_unit") else f"{value:.2f} mmol/L"
    if kind == "triglycerides":
        return f"{value * 88.57:.0f} mg/dL" if mg("blood_fat_unit") else f"{value:.2f} mmol/L"
    if kind == "uric_acid":
        return f"{value / 59.48:.1f} mg/dL" if mg("uric_acid_unit") else f"{value:.0f} µmol/L"
    if kind == "percent":
        return f"{value:.1f}%"
    if kind == "kg":
        return f"{value * 2.2046226218:.1f} lb" if units.get("weight_unit") == "lb" else f"{value:.1f} kg"
    if kind == "kcal":
        return f"{round(value):,} kcal"
    if kind == "bpm":
        return f"{round(value)} bpm"
    if kind == "ms":
        return f"{round(value)} ms"
    if kind == "breaths":
        return f"{round(value)} breaths/min"
    return f"{value:.1f}"


def units_of(settings: dict, weight_unit: str = "kg") -> dict:
    """The units the Health settings chose, as `say` reads them."""
    s = settings or {}
    return {"glucose_unit": s.get("glucose_unit") or "mmolL", "blood_fat_unit": s.get("blood_fat_unit") or "mmolL",
            "uric_acid_unit": s.get("uric_acid_unit") or "umolL", "weight_unit": weight_unit}


# ── reference ranges ─────────────────────────────────────────────────────────

def _sex(settings: Optional[dict]) -> str:
    sex = str(((settings or {}).get("profile") or {}).get("sex") or "").lower()
    return "male" if sex.startswith("m") else "female" if sex.startswith(("f", "w")) else ""


def classify(key: str, value: float, sex: str = "", diastolic: Optional[float] = None) -> Optional[dict]:
    """Where a value sits against the usual adult range: `{status, range}`, or None without one.

    `status` is one of low, normal, elevated, high; `range` says what normal is.
    """
    def out(status: str, range_: str) -> dict:
        return {"status": status, "range": range_}

    if key == "blood_pressure":
        dia = diastolic or 0
        normal = "under 120/80 mmHg"
        if value >= 180 or dia >= 120:
            return out("high", normal + " (180/120 or more is very high)")
        if value >= 130 or dia >= 80:
            return out("high", normal)
        if value >= 120:
            return out("elevated", normal)
        if value < 90 or (dia and dia < 60):
            return out("low", normal + ", above 90/60")
        return out("normal", normal)
    if key == "blood_glucose":
        normal = "3.9–5.5 mmol/L fasting"
        if value < 3.9:
            return out("low", normal)
        if value < 5.6:
            return out("normal", normal)
        return out("elevated" if value < 7.0 else "high", normal)
    if key == "cholesterol":
        return out("normal" if value < 5.2 else "elevated" if value < 6.2 else "high", "under 5.2 mmol/L")
    if key == "triglycerides":
        return out("normal" if value < 1.7 else "elevated" if value < 2.3 else "high", "under 1.7 mmol/L")
    if key == "ldl":
        return out("normal" if value < 3.4 else "elevated" if value < 4.1 else "high", "under 3.4 mmol/L")
    if key == "hdl":
        floor = 1.3 if sex == "female" else 1.0
        range_ = f"above {floor:.1f} mmol/L" + ("" if sex else " (1.3 for women)")
        return out("normal" if value >= floor else "low", range_)
    if key == "uric_acid":
        low, high = (140, 360) if sex == "female" else (200, 420) if sex == "male" else (140, 420)
        range_ = f"{low}–{high} µmol/L" + ("" if sex else " (men 200–420, women 140–360)")
        return out("low" if value < low else "high" if value > high else "normal", range_)
    if key == "bmi":
        status = "low" if value < 18.5 else "normal" if value < 25 else "elevated" if value < 30 else "high"
        return out(status, "18.5–24.9")
    if key == "respiratory_rate":
        return out("low" if value < 12 else "high" if value > 20 else "normal", "12–20 breaths/min at rest")
    if key == "ecg":
        return out("low" if value < 60 else "high" if value > 100 else "normal", "60–100 bpm at rest")
    if key == "ecg_qtc":
        limit = 460 if sex == "female" else 450
        range_ = f"under {limit} ms" + ("" if sex else " (460 for women)")
        return out("high" if value > 500 else "elevated" if value >= limit else "normal", range_)
    return None


def _age(settings: Optional[dict]) -> Optional[int]:
    try:
        age = int(((settings or {}).get("profile") or {}).get("age") or 0)
    except (TypeError, ValueError):
        return None
    return age if 10 <= age <= 110 else None


def _bar(label: str, kind: str, cuts: list, field: str = "value") -> dict:
    """A range bar: `cuts` is (status, from) in order, the last entry the bar's end."""
    segments = [{"status": status, "from": start, "to": cuts[i + 1][1]}
                for i, (status, start) in enumerate(cuts[:-1])]
    return {"label": label, "kind": kind, "field": field, "segments": segments}


def reference(key: str, sex: str = "", age: Optional[int] = None) -> list[dict]:
    """The Low / Normal / Elevated / High bars a value is drawn against, by the person's sex
    and age where the norm changes with them, in canonical units (mmol/L, µmol/L, °C, %…).
    `field` says which number of a history bucket the marker follows (`low` is blood
    pressure's diastolic). Empty without a reference. Sources: AHA (blood pressure), ADA
    (fasting glucose), NCEP ATP III (lipids), uric acid lab norms, WHO (BMI), Gallagher et al.
    2000 (body fat by age and sex), Omron (skeletal muscle by age and sex), Bazett QTc limits.
    """
    old = (age or 40) >= 60
    mid = 40 <= (age or 30) < 60
    female = sex == "female"
    if key == "blood_pressure":
        return [_bar("Systolic", "mmhg", [("low", 70), ("normal", 90), ("elevated", 120), ("high", 130), ("", 200)]),
                _bar("Diastolic", "mmhg", [("low", 40), ("normal", 60), ("high", 80), ("", 120)], field="low")]
    if key == "blood_glucose":
        # Fasting (ADA), an hour after eating (the band app's upper bound, 9.4) and two hours
        # after (ADA's 7.8 / 11.1): a band reading isn't tagged, so all three are shown.
        return [_bar("Fasting / before a meal", "glucose", [("low", 2.0), ("normal", 3.9), ("elevated", 5.6),
                                                            ("high", 7.0), ("", 15.0)]),
                _bar("1 h after a meal", "glucose", [("low", 2.0), ("normal", 3.9), ("high", 9.4), ("", 15.0)]),
                _bar("2 h after a meal", "glucose", [("low", 2.0), ("normal", 3.9), ("elevated", 7.8), ("high", 11.1),
                                                     ("", 15.0)])]
    if key == "uric_acid":
        low, high = (140, 360) if female else (200, 420) if sex == "male" else (150, 420)
        return [_bar("Uric acid", "uric_acid", [("low", 0), ("normal", low), ("high", high), ("", 1000)])]
    if key == "cholesterol":
        return [_bar("Total cholesterol", "cholesterol", [("normal", 0), ("elevated", 5.2), ("high", 6.2), ("", 10.0)])]
    if key == "triglycerides":
        return [_bar("Triglycerides", "triglycerides", [("normal", 0), ("elevated", 1.7), ("high", 2.3), ("", 6.0)])]
    if key == "ldl":
        return [_bar("LDL", "cholesterol", [("normal", 0), ("elevated", 3.4), ("high", 4.1), ("", 7.0)])]
    if key == "hdl":
        return [_bar("HDL", "cholesterol", [("low", 0), ("normal", 1.3 if female else 1.0), ("", 3.0)])]
    if key == "bmi":
        return [_bar("BMI", "number", [("low", 12), ("normal", 18.5), ("elevated", 25), ("high", 30), ("", 40)])]
    if key == "body_fat":
        if female:
            cuts = (24, 36, 42) if old else (23, 34, 40) if mid else (21, 33, 39)
        else:
            cuts = (13, 25, 30) if old else (11, 22, 28) if mid else (8, 20, 25)
        return [_bar("Body fat", "percent", [("low", 3), ("normal", cuts[0]), ("elevated", cuts[1]), ("high", cuts[2]),
                                             ("", 50)])]
    if key == "skeletal_muscle":
        if female:
            low, high = (23.0, 28.0) if old else (24.1, 29.0) if mid else (24.1, 30.1)
        else:
            low, high = (31.0, 37.0) if old else (32.0, 38.0) if mid else (33.0, 39.0)
        return [_bar("Skeletal muscle", "percent", [("low", 15), ("normal", low), ("high", high), ("", 50)])]
    if key == "body_water":
        low, high = (45, 60) if female else (50, 65)
        return [_bar("Body water", "percent", [("low", 30), ("normal", low), ("high", high), ("", 75)])]
    if key == "protein":
        return [_bar("Protein", "percent", [("low", 10), ("normal", 16), ("high", 20), ("", 25)])]
    if key in ("ecg", "heart_rate"):
        return [_bar("Resting heart rate", "bpm", [("low", 40), ("normal", 60), ("high", 100), ("", 140)])]
    if key == "respiratory_rate":
        return [_bar("Breathing rate", "breaths", [("low", 6), ("normal", 12), ("high", 20), ("", 30)])]
    if key == "ecg_qtc":
        limit = 460 if female else 450
        return [_bar("QTc", "ms", [("low", 300), ("normal", 350), ("elevated", limit), ("high", 500), ("", 600)])]
    if key == "spo2":
        return [_bar("Blood oxygen", "percent", [("low", 85), ("elevated", 90), ("normal", 95), ("", 100)])]
    if key == "temperature":
        return [_bar("Body temperature", "celsius", [("low", 34.5), ("normal", 36.1), ("elevated", 37.3), ("high", 38.0),
                                                     ("", 40.0)])]
    return []


_STATUS_WORDS = {"low": "below the usual range", "normal": "in the usual range",
                 "elevated": "in the elevated range", "high": "in the high range"}


def verdict(key: str, value: float, sex: str = "", diastolic: Optional[float] = None) -> str:
    """One sentence on where a value sits, ending with the wrist-band caveat; "" without a range."""
    found = classify(key, value, sex, diastolic)
    if not found:
        return ""
    return f"That is {_STATUS_WORDS[found['status']]} ({found['range']}). {NOTE}"


# ── over time ────────────────────────────────────────────────────────────────

def readings_between(store, first: str, last: str) -> list[dict]:
    """Every reading on the local days `first`…`last` from the linked wearables, oldest first."""
    from .merge import merged_day

    out: list[dict] = []
    day, end = Date.fromisoformat(first), Date.fromisoformat(last)
    stored = set(store.dates(100_000))
    while day <= end:
        name = day.isoformat()
        if name in stored:
            merged = merged_day(store, name)
            if merged is not None:
                out += readings(merged.measurements)
        day += timedelta(days=1)
    unique = {(r["metric"], r["at"]): r for r in out}
    return sorted(unique.values(), key=lambda r: r["at"])


def _trend(key: str, recent: list[float], before: list[float]) -> Optional[str]:
    if not recent or not before:
        return None
    diff = mean(recent) - mean(before)
    if abs(diff) < VITALS[key].step:
        return "steady"
    return "rising" if diff > 0 else "falling"


def insights(store, today: str, days: int = 30, settings: Optional[dict] = None,
             weight_unit: str = "kg") -> dict:
    """What the readings of the last `days` days say: per vital its latest value, where it
    sits against the usual range, the last week against the weeks before, and plain
    sentences an assistant can pass on. Never a diagnosis."""
    settings = settings if settings is not None else store.settings()
    sex, units = _sex(settings), units_of(settings, weight_unit)
    last = Date.fromisoformat(today)
    first = last - timedelta(days=max(1, days) - 1)
    rows = readings_between(store, first.isoformat(), last.isoformat())
    week_start = (last - timedelta(days=6)).isoformat()

    metrics: dict[str, dict] = {}
    sentences: list[str] = []
    for key, vital in VITALS.items():
        mine = [r for r in rows if r["metric"] == key]
        if not mine:
            continue
        latest = mine[-1]
        recent = [r for r in mine if r["at"][:10] >= week_start]
        before = [r for r in mine if r["at"][:10] < week_start]
        avg = round(mean(r["value"] for r in mine), 2)
        dia = round(mean(r["diastolic"] for r in mine), 1) if key == "blood_pressure" else None
        trend = _trend(key, [r["value"] for r in recent], [r["value"] for r in before])
        status = classify(key, latest["value"], sex, latest.get("diastolic"))
        entry = {
            "title": vital.title,
            "kind": vital.kind,
            "count": len(mine),
            "latest": {**latest, "text": say(vital.kind, latest["value"], units, latest.get("diastolic"))},
            "average": avg,
            "average_text": say(vital.kind, avg, units, dia),
            "lowest": min(r["value"] for r in mine),
            "highest": max(r["value"] for r in mine),
            "last_7_days_average": round(mean(r["value"] for r in recent), 2) if recent else None,
            "before_average": round(mean(r["value"] for r in before), 2) if before else None,
            "trend": trend,
            "status": status["status"] if status else None,
            "reference": status["range"] if status else None,
            # The range bars for this person (sex, age), as the history screen draws them.
            "bars": reference(key, sex, _age(settings)),
        }
        if dia is not None:
            entry["average_diastolic"] = dia
        metrics[key] = entry

        moment = parse_instant(latest["at"])
        when = f"{moment:%b} {moment.day}"
        line = f"{vital.title}: latest {entry['latest']['text']} ({when})"
        if status:
            line += f", {_STATUS_WORDS[status['status']]} ({status['range']})"
        if trend in ("rising", "falling"):
            line += f"; {trend} this week ({say(vital.kind, entry['last_7_days_average'], units)} vs " \
                    f"{say(vital.kind, entry['before_average'], units)} before)"
        sentences.append(line + ".")
        # Repeated readings out of range are worth saying on their own.
        flagged = [r for r in mine[-5:] if (classify(key, r["value"], sex, r.get("diastolic")) or {}).get("status")
                   in ("high", "elevated")]
        if len(flagged) >= 3:
            sentences.append(f"{len(flagged)} of the last {min(5, len(mine))} {vital.title.lower()} readings were "
                             f"above the usual range.")

    return {
        "start": first.isoformat(),
        "end": last.isoformat(),
        "disclaimer": DISCLAIMER,
        "metrics": metrics,
        "insights": sentences,
        "readings": rows[-200:],
    }
