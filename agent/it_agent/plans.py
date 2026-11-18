"""Code-checked model replies for the IT agent: JSON parsing and plan/brief validation. A rejected reply is
re-asked with the exact rule it broke (a phase without a check never gets through)."""
from __future__ import annotations

import json
import re
import unicodedata
from typing import Callable

from agent.it_agent.classify import classify
from agent.it_agent.model import (ADMIN_MAX_CHARS, CHECK_KINDS, MAX_PHASES, MAX_STEPS, SHELL_MAX_CHARS, STEP_KINDS,
                                  Brief, Check, Phase, PlanError, Step)

_RESTART = re.compile(r"\bshutdown(?:\.exe)?\b[^\n]*\s/r\b|\bRestart-Computer\b|\bStop-Computer\b", re.I)


def extract_json(text) -> dict:
    """The JSON object in a reply (``` fences stripped; first ``{`` through last ``}``)."""
    s = str(text or "").strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
    a, b = s.find("{"), s.rfind("}")
    if a < 0 or b <= a:
        raise PlanError("no JSON object in the reply")
    try:
        out = json.loads(s[a:b + 1])
    except ValueError as exc:
        raise PlanError(f"bad JSON: {exc}") from None
    if not isinstance(out, dict):
        raise PlanError("the reply must be one JSON object")
    return out


def _clamp(value, default: int, low: int, high: int) -> int:
    try:
        v = int(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, v))


def _strs(value) -> list:
    """A list of non-empty strings; one string is one item (never split into letters)."""
    items = value if isinstance(value, list) else [value] if isinstance(value, str) else []
    return [str(v).strip() for v in items if str(v).strip()]


def _hidden(text: str) -> bool:
    """Characters that make a command read differently from what runs (bidi overrides, zero-width, controls)."""
    return any(unicodedata.category(c) in ("Cf", "Cc") and c not in "\t\n\r" for c in text)


def parse_queries(text) -> list:
    qs = _strs(extract_json(text).get("queries"))
    if not 2 <= len(qs) <= 5:
        raise PlanError("give 2–5 search queries")
    return qs


def parse_pick(text, allowed: list) -> list:
    """URLs from ``allowed`` only, at most 6; [] (fall back) on anything unusable — never raises."""
    try:
        found = extract_json(text)
        urls = found.get("read") or found.get("urls") or []
    except PlanError:
        return []
    seen, out = set(allowed), []
    for u in urls:
        if isinstance(u, str) and u in seen and u not in out:
            out.append(u)
    return out[:6]


def parse_brief(text, sources) -> Brief:
    d = extract_json(text)
    route = str(d.get("route") or "").strip()
    checks = _strs(d.get("checks"))
    research_only = d.get("research_only") is True   # a real JSON true: "false" is not a yes
    answer = str(d.get("answer") or "").strip()
    if not route:
        raise PlanError("the brief needs a route")
    if research_only and not answer:
        raise PlanError("a research-only brief needs the answer")
    if not research_only and not checks:
        raise PlanError("the brief needs the checks to run")
    return Brief(summary=str(d.get("summary") or "").strip(),
                 requirements=_strs(d.get("requirements")),
                 route=route, checks=checks, sources=list(sources or []), research_only=research_only,
                 answer=answer)


def _check(i: int, raw) -> Check:
    if not isinstance(raw, dict):
        raise PlanError(f"phase {i} has no check")
    kind = str(raw.get("kind") or "")
    if kind not in CHECK_KINDS:
        raise PlanError(f"phase {i} check kind must be shell or screen")
    expect = raw.get("expect") or {}
    if not isinstance(expect, dict):
        raise PlanError(f"phase {i} check expect must be an object like {{\"exit_code\": 0, \"contains\": \"…\"}}")
    command = str(raw.get("command") or "").strip()
    if _hidden(command):
        raise PlanError(f"phase {i} check command has hidden characters")
    if kind == "shell" and not command:
        raise PlanError(f"phase {i} check needs a command")
    if command:
        verdict = classify(command)
        if verdict.destructive or verdict.refuse:
            raise PlanError(f"phase {i} check must not change anything: {verdict.reason}")
    contains, regex = str(expect.get("contains") or ""), str(expect.get("regex") or "")
    if kind == "screen" and not (contains or regex):
        raise PlanError(f"phase {i} screen check needs expect.contains or expect.regex")
    if regex:
        try:
            re.compile(regex)
        except re.error as exc:
            raise PlanError(f"phase {i} expect.regex doesn't compile: {exc}") from None
    exit_code = expect.get("exit_code", 0 if kind == "shell" else None)
    if kind == "shell" and exit_code is None and not (contains or regex or expect.get("not_contains")):
        raise PlanError(f"phase {i} check must test something (exit_code, contains, not_contains or regex)")
    return Check(kind=kind, command=command, app=str(raw.get("app") or ""),
                 timeout_s=_clamp(raw.get("timeout_s"), 120, 5, 600),
                 exit_code=None if exit_code is None else _clamp(exit_code, 0, -2**31, 2**31),
                 contains=contains, not_contains=str(expect.get("not_contains") or ""), regex=regex)


def _step(i: int, j: int, raw) -> Step:
    raw = raw if isinstance(raw, dict) else {}
    kind = str(raw.get("kind") or "")
    if kind not in STEP_KINDS:
        raise PlanError(f"phase {i} step {j}: unknown kind '{kind}'")
    command = str(raw.get("command") or "").strip()
    if kind in ("shell", "admin"):
        if not command:
            raise PlanError(f"phase {i} step {j}: shell/admin steps need a command")
        cap = ADMIN_MAX_CHARS if kind == "admin" else SHELL_MAX_CHARS
        if len(command) > cap:
            raise PlanError(f"phase {i} step {j}: command too long (max {cap} characters)")
        if _RESTART.search(command):
            raise PlanError(f"phase {i} step {j}: restart commands aren't steps; set restart_after")
        if _hidden(command):
            raise PlanError(f"phase {i} step {j}: the command has hidden characters (bidi, zero-width or control)")
    codes = raw.get("ok_exit_codes") or [0]
    return Step(kind=kind, command=command, goal=str(raw.get("goal") or "").strip(),
                why=str(raw.get("why") or "").strip(), timeout_s=_clamp(raw.get("timeout_s"), 300, 5, 1800),
                ok_exit_codes=[_clamp(c, 0, -2**31, 2**31) for c in codes] if isinstance(codes, list) else [0])


def parse_plan(text) -> list:
    phases = extract_json(text).get("phases")
    if not isinstance(phases, list) or not phases:
        raise PlanError("the plan has no phases")
    if len(phases) > MAX_PHASES:
        raise PlanError(f"too many phases (max {MAX_PHASES})")
    out = []
    for i, raw in enumerate(phases, 1):
        raw = raw if isinstance(raw, dict) else {}
        name = str(raw.get("name") or f"Phase {i}").strip()
        steps = raw.get("steps") if isinstance(raw.get("steps"), list) else []
        if not 1 <= len(steps) <= MAX_STEPS:
            raise PlanError(f"phase {i} ('{name}') needs 1–10 steps")
        if not raw.get("check"):
            raise PlanError(f"phase {i} ('{name}') has no check")
        out.append(Phase(name=name, steps=[_step(i, j, s) for j, s in enumerate(steps, 1)],
                         check=_check(i, raw["check"]), restart_after=bool(raw.get("restart_after"))))
    return out


def parse_rethink(text):
    """New phases for the rest of the run, or the give-up reason (``{"give_up": "..."}``)."""
    d = extract_json(text)
    if d.get("give_up"):
        return str(d["give_up"]).strip()
    return parse_plan(json.dumps(d))


def ask_json(ask: Callable, purpose: str, prompt: str, parse: Callable, *, max_tokens: int, tries: int = 3):
    """Ask, parse, and re-ask with the rule the reply broke; PlanError after ``tries`` failures."""
    last, current = "", prompt
    for _ in range(tries):
        reply = ask(purpose, current, max_tokens)
        try:
            return parse(reply)
        except PlanError as exc:
            last = str(exc)
        except (AttributeError, TypeError, ValueError, KeyError) as exc:   # a field of the wrong type
            last = f"malformed reply ({type(exc).__name__}: {exc})"
        current = prompt + f"\n\nYour last reply was rejected: {last}. Reply again with ONLY the JSON."
    raise PlanError(f"gave up after {tries} tries: {last}")
