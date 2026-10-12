"""Skills and tools first.

A model that only "sees" the skills catalogue in its system prompt often
improvises instead of loading the skill that fits (observed: the morning brief
was assembled ad hoc until the user said "use the skill"). So the server looks
for the fit itself, every turn, on every surface and provider: the user's
message is scored against each skill (name, description, tags, and optional
``triggers`` phrases in its frontmatter) and against the on-demand tool
catalogue, and a confident match becomes one line in the turn's context —
"The `morning-brief` skill matches this request. Load it with skill_view…".
That rides the current user message (never the system prompt), so the cached
prompt start is untouched.

Scoring is local BM25 (no model call). The index is rebuilt whenever a
SKILL.md is added, removed or edited (a cheap stat fingerprint, checked each
turn), so a new skill is matched on the very next message.

Config (``skills.match`` in config.yaml): ``enabled`` (default true),
``threshold`` (default 1.7; higher = fewer, surer hints).
"""
from __future__ import annotations

import json
import logging
import math
import re
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

logger = logging.getLogger(__name__)

# A match must clear THRESHOLD × the rarest word's weight (ln(1 + N/1.5) for
# N skills), so the bar follows the size of the skill library: calibrated on
# 131 real skills × 1,143 real messages (right hints scored 8–20, coincidences
# 3–7, where the scale factor is ≈4.5).
_THRESHOLD = 1.7
_MARGIN = 1.3
_MAX_TOOLS = 3
_K1, _B = 1.2, 0.75

_STOP = frozenset("""
a an the and or of to in on for with at by from as is are be am was were it its this that these those i me my
mine you your we our us he she they them his her their can could would should will shall may might do does did
please give get got want wants need needs let lets tell show what whats which who whom how when where why use used
using asks ask asked user pranav about any some all just also now then there here so if not no yes ok okay hey hi
hello thanks thank jarvis sir up out into over than too very more most only own same such via per
model tool tools answer reply final result results um uh like okay mm hmm yeah
don doesn didn isn wasn won wouldn couldn shouldn aren ve ll re
""".split())

_WORD = re.compile(r"[a-z0-9]+")


def _stem(w: str) -> str:
    for suf in ("ing", "ed", "es", "s"):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def _tokens(text: str) -> List[str]:
    # Bare numbers ("1 cup", "7 am") and one-letter scraps ("what's" → s)
    # say nothing about which skill fits.
    return [_stem(w) for w in _WORD.findall((text or "").lower())
            if w not in _STOP and not w.isdigit() and len(w) > 1]


def _as_list(value) -> List[str]:
    if isinstance(value, str):
        return [value] if value.strip() else []
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value if str(v).strip()]
    return []


def _doc_tokens(entry: dict) -> List[str]:
    name = str(entry.get("name") or "").replace("-", " ").replace("_", " ")
    # Name, triggers and tags say what a skill is FOR; weight them over prose.
    toks = _tokens(name) * 3
    for t in _as_list(entry.get("triggers")):
        toks += _tokens(t) * 3
    for t in _as_list(entry.get("tags")):
        toks += _tokens(t) * 2
    toks += _tokens(entry.get("description") or "")
    return toks


def _bm25(query: List[str], docs: List[List[str]]) -> List[float]:
    n = len(docs)
    if not n or not query:
        return [0.0] * n
    avg = sum(len(d) for d in docs) / n or 1.0
    df: Dict[str, int] = {}
    for d in docs:
        for t in set(d):
            df[t] = df.get(t, 0) + 1
    scores = []
    q = set(query)
    for d in docs:
        tf: Dict[str, int] = {}
        for t in d:
            if t in q:
                tf[t] = tf.get(t, 0) + 1
        s = 0.0
        for t, f in tf.items():
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            s += idf * f * (_K1 + 1) / (f + _K1 * (1 - _B + _B * len(d) / avg))
        scores.append(s)
    return scores


def _phrase_hit(text: str, entry: dict) -> bool:
    low = " " + re.sub(r"[^a-z0-9]+", " ", (text or "").lower()) + " "
    phrases = _as_list(entry.get("triggers"))
    name = str(entry.get("name") or "").replace("-", " ").replace("_", " ").strip()
    if len(name.split()) > 1:
        phrases.append(name)
    for p in phrases:
        norm = re.sub(r"[^a-z0-9]+", " ", p.lower()).strip()
        if norm and f" {norm} " in low:
            return True
    return False


def _rank(text: str, entries: List[dict], min_score: float):
    query = _tokens(text)
    docs = [_doc_tokens(e) for e in entries]
    scores = _bm25(query, docs)
    q = set(query)
    ranked = []
    for e, d, s in zip(entries, docs, scores):
        if _phrase_hit(text, e):
            s += min_score
        elif len(q & set(d)) < 2:
            # One shared word is coincidence ("set an alarm" vs the door
            # alarm skill, "what's the weather" vs the morning brief); a fit
            # shares two (or a trigger phrase).
            s = 0.0
        ranked.append((s, e))
    ranked.sort(key=lambda x: -x[0])
    return ranked


def _min_score(n: int, threshold: float) -> float:
    return threshold * math.log(1 + max(n, 1) / 1.5)


def match(text: str, skills: List[dict], tools: Optional[List[dict]] = None, *,
          loaded: Iterable[str] = frozenset(), threshold: float = _THRESHOLD) -> dict:
    """``{"skill": name | None, "score": float, "tools": [names]}`` for ``text``.

    A skill is named only when it clears the bar (``threshold`` × the rarest
    word's weight for this many skills) and leads the runner-up by a clear
    margin; one already loaded in this chat is never named again.
    """
    loaded = set(loaded or ())
    out = {"skill": None, "score": 0.0, "tools": []}
    if not (text or "").strip():
        return out
    skills = list(skills or [])
    min_score = _min_score(len(skills), threshold)
    ranked = _rank(text, skills, min_score)
    if ranked:
        top_s, top = ranked[0]
        second = ranked[1][0] if len(ranked) > 1 else 0.0
        if top_s >= min_score and top_s >= second * _MARGIN and top.get("name") not in loaded:
            out["skill"], out["score"] = top.get("name"), round(top_s, 2)
    if tools:
        tools = list(tools)
        tool_min = _min_score(len(tools), threshold)
        out["tools"] = [e.get("name") for s, e in _rank(text, tools, tool_min)[:_MAX_TOOLS]
                        if s >= tool_min and e.get("name")]
    return out


def hint_text(result: dict) -> str:
    """The turn-context line for a ``match`` result ("" when nothing fits)."""
    lines = []
    if result.get("skill"):
        lines.append(f"The `{result['skill']}` skill matches this request. Load it with "
                     f"skill_view(\"{result['skill']}\") and follow its steps before answering.")
    if result.get("tools"):
        lines.append("These tools may help: " + ", ".join(result["tools"])
                     + " (load with tool_search, then call through tool_call).")
    return "\n".join(lines)


def loaded_skills(history: Iterable[dict]) -> set:
    """Skill names already opened with skill_view in this chat (direct or
    through the tool_call bridge)."""
    names = set()
    for m in history or []:
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        for c in m.get("tool_calls") or []:
            fn = ((c or {}).get("function") or {}) if isinstance(c, dict) else {}
            name, args = fn.get("name"), fn.get("arguments")
            try:
                args = json.loads(args) if isinstance(args, str) else (args or {})
            except ValueError:
                continue
            if name == "tool_call" and isinstance(args, dict):
                name, args = args.get("name"), args.get("arguments") or {}
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except ValueError:
                        args = {}
            if name == "skill_view" and isinstance(args, dict) and args.get("name"):
                names.add(str(args["name"]))
    return names


_MANIFEST_LINE = re.compile(r"^- (\S+)(?: — (.*))?$")


def manifest_tools(manifest: str) -> List[dict]:
    """The on-demand tools listed in a deferred-tools manifest."""
    out = []
    for line in (manifest or "").splitlines():
        m = _MANIFEST_LINE.match(line.strip())
        if m:
            out.append({"name": m.group(1), "description": (m.group(2) or "").strip()})
    return out


# ── the skill index (rebuilt when SKILL.md files change) ─────────────────────

def read_skill_docs(dirs: Iterable[Path], disabled: Iterable[str] = ()) -> List[dict]:
    """``[{name, description, tags, triggers}]`` for every SKILL.md under
    ``dirs`` (first directory wins on a name clash)."""
    from agent.skill_utils import iter_skill_index_files, parse_frontmatter
    disabled = set(disabled or ())
    docs, seen = [], set()
    for d in dirs:
        d = Path(d)
        if not d.exists():
            continue
        for skill_md in iter_skill_index_files(d, "SKILL.md"):
            try:
                fm, _ = parse_frontmatter(skill_md.read_text(encoding="utf-8")[:6000])
            except Exception:
                continue
            fm = fm if isinstance(fm, dict) else {}
            name = str(fm.get("name") or skill_md.parent.name)
            if name in seen or name in disabled:
                continue
            seen.add(name)
            meta = fm.get("metadata") if isinstance(fm.get("metadata"), dict) else {}
            meta = meta.get("jarviscopilot") if isinstance(meta.get("jarviscopilot"), dict) else {}
            docs.append({
                "name": name,
                "description": str(fm.get("description") or ""),
                "tags": _as_list(meta.get("tags") or fm.get("tags")),
                "triggers": _as_list(meta.get("triggers") or fm.get("triggers")),
            })
    return docs


_INDEX_LOCK = threading.Lock()
_INDEX: Dict[str, Any] = {"key": None, "docs": []}


def _fingerprint(dirs: List[Path]):
    """(count, newest mtime, total size) of every SKILL.md — changes when a
    skill is added, removed or edited."""
    from agent.skill_utils import iter_skill_index_files
    count = newest = size = 0
    for d in dirs:
        if not d.exists():
            continue
        for p in iter_skill_index_files(d, "SKILL.md"):
            try:
                st = p.stat()
            except OSError:
                continue
            count += 1
            newest = max(newest, st.st_mtime_ns)
            size += st.st_size
    return (tuple(str(d) for d in dirs), count, newest, size)


def skill_index() -> List[dict]:
    """The current skill docs, rebuilt whenever the skills on disk change."""
    try:
        from agent.skill_utils import get_all_skills_dirs, get_disabled_skill_names
        dirs = [Path(d) for d in get_all_skills_dirs()]
        disabled = get_disabled_skill_names()
    except Exception:
        logger.debug("skills dirs unavailable", exc_info=True)
        return []
    key = (_fingerprint(dirs), tuple(sorted(disabled)))
    with _INDEX_LOCK:
        if _INDEX["key"] != key:
            _INDEX["docs"] = read_skill_docs(dirs, disabled)
            _INDEX["key"] = key
        return list(_INDEX["docs"])


def _config() -> dict:
    try:
        from jarviscopilot_cli.config import load_config
        return ((load_config() or {}).get("skills", {}) or {}).get("match") or {}
    except Exception:
        return {}


def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(p.get("text") or "") for p in content if isinstance(p, dict))
    return ""


_HANDOFF_NOTE = "Hand-off note:"
_LEADING_TAG = re.compile(r"^\s*\[[^\]\n]{1,200}\]\s*")


def user_words(text: str) -> str:
    """The user's own words in a turn's text: no leading ``[Workspace::…]``
    tag, no server notes appended after a blank line (``[Your active task
    list was preserved…]``), and for a hand-off only the note itself."""
    text = text or ""
    if _HANDOFF_NOTE in text:
        text = text.split(_HANDOFF_NOTE, 1)[1]
    text = _LEADING_TAG.sub("", text)
    text = re.split(r"\n\s*\n\[", text, maxsplit=1)[0]
    return text.strip()


def hint_for(agent, user_content, history) -> str:
    """This turn's skills-and-tools line for ``agent`` ("" when nothing fits,
    the matcher is off, or the turn is a scheduled job / slash command)."""
    try:
        cfg = _config()
        if cfg.get("enabled") is False:
            return ""
        if (getattr(agent, "platform", "") or "").lower() == "cron":
            return ""  # a schedule's prompt is its own instructions (its skills are set on the job)
        text = user_words(_text_of(user_content))
        if not text or text.startswith("/"):
            return ""
        try:
            threshold = float(cfg.get("threshold", _THRESHOLD))
        except (TypeError, ValueError):
            threshold = _THRESHOLD
        tools = manifest_tools(getattr(agent, "_lazy_tools_manifest", "") or "")
        result = match(text[:2000], skill_index(), tools, loaded=loaded_skills(history),
                       threshold=threshold)
        return hint_text(result)
    except Exception:
        logger.debug("skill matcher failed", exc_info=True)
        return ""
