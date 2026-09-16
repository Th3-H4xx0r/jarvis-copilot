"""Move the workspace trackers and the loose cron jobs into the registry, once.

Before this, a tracker was a folder — ``casino-earnings-tracker/ledger.csv``,
``email-monitor/life_log.json``, ``house-watch/state/watch_state.json`` — and the cron
jobs that fed those folders knew nothing about each other. This reads those files into
the right integration's space and tags every schedule with the integration it belongs
to.

Two rules keep the migration from breaking what it is organising:

* **Scripts are not data.** A ``.py`` or ``.sh`` in a tracker folder is what a schedule
  runs. Only the files listed in a ``Source`` below are touched.
* **A file is deleted only when it is dead.** Sources carry ``delete=True`` only for
  data nothing reads any more (rotated backups, pre-change snapshots). Live state — the
  cursor the email monitor resumes from, the notify state that stops a flight alert
  firing twice — is copied into the registry and left in place until its reader has been
  repointed. Everything imported is recorded in the space's ``imported_files`` document
  with a digest, so a second run is a no-op, and anything deleted goes into one dated
  tarball first.
"""
from __future__ import annotations

import calendar
import csv
import hashlib
import io
import json
import logging
import tarfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Optional

logger = logging.getLogger(__name__)

IMPORT_MARKER = "imported_files"
_MAX_RECORDS_PER_FILE = 5000
_MAX_TEXT_CHARS = 200_000
BY_NAME = "*"          # document key comes from the file name


@dataclass
class Source:
    """One data file (or glob) to pull into a space."""

    glob: str
    collection: str = ""          # CSV rows / JSON lists become records here
    document: str = ""            # a JSON object becomes this document (BY_NAME: per file)
    description: str = ""
    ts_field: str = ""            # which field carries a record's time
    whole_file: bool = False      # a JSON list is one record, not one per element
    delete: bool = False          # only for data nothing reads any more


@dataclass
class Plan:
    """One integration: what it is, what it owns, which schedules are its."""

    space_id: str
    name: str
    description: str
    icon: str = ""
    sources: list[Source] = field(default_factory=list)
    job_patterns: list[str] = field(default_factory=list)


# Pranav's workspace as it stands, classified by what the data is for.
PLANS: list[Plan] = [
    Plan("vibeforge", "VibeForge", "Spotify taste, plays and the playlists Jarvis keeps fresh.",
         "music",
         [Source("vibeforge-spotify/config.json", document="config",
                 description="Spotify accounts and the playlists VibeForge manages"),
          Source("vibeforge-spotify/data/playlists.json", document="playlists",
                 description="every managed playlist and what is currently on it"),
          Source("vibeforge-spotify/data/saved_library_snapshot.json", document="library_snapshot",
                 description="the saved library the last scan captured"),
          Source("vibeforge-spotify/data/weekly_summary.json", document="weekly_summary",
                 description="the most recent week in music: top artists, labels, changes"),
          Source("vibeforge-spotify/data/last_playlist_update.json", document="last_update",
                 description="when each playlist was last rebuilt"),
          Source("vibeforge-spotify/data/snapshots/weekly_summary_*.md",
                 collection="weekly_summaries",
                 description="the week in music, as it was written up that Sunday",
                 delete=True),
          Source("vibeforge-spotify/data/snapshots/*.json", collection="playlist_snapshots",
                 description="a playlist as it stood just before a rebuild",
                 whole_file=True, delete=True),
          Source("vibeforge-spotify/data/*.pre_clean_start.*.json",
                 collection="playlist_snapshots",
                 description="a playlist as it stood just before a rebuild",
                 whole_file=True, delete=True)],
         ["vibeforge-*"]),

    Plan("email-monitor", "Email Monitor",
         "Watches the inboxes, keeps the life log and raises reminders.", "envelope",
         [Source("email-monitor/config.json", document="config",
                 description="the accounts the monitor reads and the rules it applies"),
          Source("email-monitor/state.json", document="inbox_state",
                 description="where the inbox scan left off"),
          Source("email-monitor/sent_state.json", document="sent_state",
                 description="where the sent-mail scan left off"),
          Source("email-monitor/life_log.json", document="life_log",
                 description="what email has told us about Pranav's life, by category"),
          Source("email-monitor/reminders.json", document="reminders",
                 description="follow-ups raised from email, and when they are due"),
          Source("email-monitor/.backups/*.json", collection="backups",
                 description="a life log or reminder file kept before an edit", delete=True)],
         ["email-*", "Reminder"]),

    Plan("house-watch", "House Watch",
         "Security events from the cameras and the daily health of the house.", "house",
         [Source("house-watch/state/watch_state.json", document="watch_state",
                 description="what each sensor was doing when the watcher last looked")],
         ["House Watch*", "House Health*"]),

    Plan("flight-tracking", "Flight Tracking",
         "Flights Jarvis follows, and the Dynamic Islands that show them.", "airplane",
         [Source("flight-tracking-common/state/*.json", document=BY_NAME,
                 description="cached flight data and per-trip notification state"),
          Source("*-flight-island/*.json", document=BY_NAME,
                 description="a tracked flight: its design, payload and overrides"),
          Source("*-flight-island/state/*.json", document=BY_NAME,
                 description="how often the tracker is polling right now")],
         ["*flight*", "*Flight*"]),

    Plan("casino", "Casino Earnings", "Casino visits, what went in and what came back.",
         "chips",
         [Source("casino-earnings-tracker/ledger.csv", collection="sessions",
                 description="one casino visit: game, buy-in, cash-out, hours",
                 ts_field="date"),
          Source("casino-earnings-tracker/summary.json", document="summary",
                 description="totals across every session the ledger holds")],
         ["casino*"]),

    Plan("market", "Market & Stocks",
         "Market collection, the morning brief and the Alpaca monitor.", "chart",
         [Source("market_*.json", collection="snapshots",
                 description="a market snapshot as collected")],
         ["*market*", "*stock*", "intellistock*", "*orning*rief*", "*alpaca*", "*Alpaca*"]),

    Plan("general", "General", "Schedules and notes that don't belong to a larger integration.",
         "dots", [], []),
]


def import_all(workspace: Path | str, *, delete: bool = True,
               plans: Optional[Iterable[Plan]] = None) -> dict:
    """Import every plan's data and tag its schedules. Returns what it did."""
    workspace = Path(workspace)
    from jarvis_registry.store import shared

    reg = shared()
    report: dict[str, Any] = {"workspace": str(workspace), "integrations": [], "archive": None}
    doomed: list[Path] = []

    for plan in (plans if plans is not None else PLANS):
        space = reg.space(plan.space_id, name=plan.name, description=plan.description,
                          icon=plan.icon)
        seen = space.get(IMPORT_MARKER, default={}) or {}
        entry: dict[str, Any] = {"id": plan.space_id, "name": plan.name, "files": [],
                                 "skipped": [], "failed": [], "records": 0, "documents": 0}

        for source in plan.sources:
            for path in sorted(workspace.glob(source.glob)):
                if not path.is_file():
                    continue
                key = str(path.relative_to(workspace))
                digest = _digest(path)
                if seen.get(key, {}).get("sha") == digest:
                    entry["skipped"].append(key)
                    if source.delete:
                        doomed.append(path)
                    continue
                try:
                    counts = _import_file(space, path, source, key)
                except Exception as exc:
                    # A corrupt file is worth reporting, not worth stopping the migration.
                    logger.warning("importer: %s could not be read: %s", key, exc)
                    entry["failed"].append({"file": key, "error": str(exc)})
                    continue
                entry["records"] += counts["records"]
                entry["documents"] += counts["documents"]
                entry["files"].append(key)
                seen[key] = {"sha": digest, "at": time.time(), **counts}
                if source.delete:
                    doomed.append(path)

        if seen:
            space.put(IMPORT_MARKER, seen,
                      description="Workspace files already pulled into this space")
        entry["jobs_tagged"] = _tag_jobs(plan)
        report["integrations"].append(entry)

    if delete and doomed:
        report["archive"] = str(_archive_and_remove(workspace, doomed))
    report["deleted"] = [str(p.name) for p in doomed] if delete else []
    return report


# ── one file ─────────────────────────────────────────────────────────────────
def _import_file(space, path: Path, source: Source, rel: str) -> dict:
    """Import one file, or leave the space exactly as it was.

    Rows are appended one at a time, so a file that fails halfway would otherwise
    leave its first rows behind — and because a failed file is never written into
    `imported_files`, the next run would append them all over again. Anything this
    call wrote is taken back out before the error is re-raised.
    """
    written: list[int] = []
    try:
        return _write_file(space, path, source, rel, written)
    except Exception:
        for record_id in written:
            try:
                space.delete_record(record_id)
            except Exception:              # nothing better to do than say so
                logger.warning("importer: %s left record %s behind", rel, record_id)
        raise


def _write_file(space, path: Path, source: Source, rel: str, written: list[int]) -> dict:
    counts: dict[str, Any] = {"records": 0, "documents": 0}
    # No errors="replace": mangling a file into U+FFFD and calling it imported is how
    # the tarball becomes the only readable copy of a file marked "done".
    text = path.read_text(encoding="utf-8")

    if path.suffix.lower() == ".csv":
        all_rows = list(csv.DictReader(io.StringIO(text)))
        rows = all_rows[:_MAX_RECORDS_PER_FILE]
        if len(all_rows) > len(rows):
            counts["truncated"] = len(all_rows) - len(rows)
            logger.warning("importer: %s has %d rows; kept the first %d",
                           rel, len(all_rows), len(rows))
        collection = source.collection or _key(rel)
        for row in rows:
            body = {k: _coerce(v) for k, v in row.items() if k}
            extra = row.get(None)          # columns past the header, kept not dropped
            if extra:
                body["_extra_columns"] = [_coerce(v) for v in extra]
            written.append(space.append(collection, _safe_body(body),
                                        ts=_row_time(body, source.ts_field),
                                        source=f"import:{path.name}"))
        counts["records"] = len(rows)
        _describe(space, collection, source.description)
        return counts

    if path.suffix.lower() in (".md", ".txt"):
        collection = source.collection or _key(rel)
        if len(text) > _MAX_TEXT_CHARS:
            counts["truncated"] = len(text) - _MAX_TEXT_CHARS
            logger.warning("importer: %s is %d characters; kept the first %d",
                           rel, len(text), _MAX_TEXT_CHARS)
        written.append(space.append(collection,
                                    {"file": path.name, "text": text[:_MAX_TEXT_CHARS]},
                                    ts=_name_time(path), source=f"import:{path.name}"))
        counts["records"] = 1
        _describe(space, collection, source.description)
        return counts

    data = json.loads(text) if text.strip() else {}

    if source.document:
        key = _key(rel) if source.document == BY_NAME else source.document
        space.put(key, data if isinstance(data, dict) else {"value": data},
                  description=source.description or None)
        counts["documents"] = 1
        return counts

    collection = source.collection or _key(rel)
    items = [data] if source.whole_file or not isinstance(data, list) else data
    kept = items[:_MAX_RECORDS_PER_FILE]
    if len(items) > len(kept):
        counts["truncated"] = len(items) - len(kept)
        logger.warning("importer: %s holds %d items; kept the first %d",
                       rel, len(items), len(kept))
    for item in kept:
        body = item if isinstance(item, dict) else {"value": item}
        written.append(space.append(collection, _safe_body({"file": path.name, **body}),
                                    ts=_row_time(body, source.ts_field) or _name_time(path),
                                    source=f"import:{path.name}"))
    counts["records"] = len(kept)
    _describe(space, collection, source.description)
    return counts


def _safe_body(body: dict) -> dict:
    """Move aside any field that would hide the record's own id, ts or source.

    The store refuses such a body outright, which is right for code being written
    now — but a workspace file that happens to have a column called `ts` should
    still import, under a name that does not lie.
    """
    from jarvis_registry.store import RESERVED_FIELDS

    clashes = [f for f in RESERVED_FIELDS if f in body]
    if not clashes:
        return body
    out = dict(body)
    for field_name in clashes:
        out[f"source_{field_name}"] = out.pop(field_name)
    return out


def _describe(space, collection: str, description: str) -> None:
    if description:
        space.collection(collection).describe(description)


def _key(rel: str) -> str:
    """A document key from the path, so two state.json files stay two documents.

    Built from the tail inward: two long paths usually differ at the end, and
    ``slug()`` truncates to the first 64 characters, so slugging the whole path
    first would throw away exactly the part that tells them apart.
    """
    import re

    from jarvis_registry.store import slug

    flat = re.sub(r"[^a-z0-9]+", "-", rel.rsplit(".", 1)[0].lower()).strip("-")
    return slug(flat[-64:].strip("-")) or "file"


_NUMBER_RE = __import__("re").compile(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$")


def _coerce(value: Any) -> Any:
    """CSV hands back strings; keep plain numbers numeric so they can be summed.

    Only what looks exactly like a JSON number converts. "007" keeps its zeros (it
    is an id, not seven), "1_0" stays text (Python's int() would read 10), and
    "nan"/"inf" stay text because neither is a value JSON can carry.
    """
    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text or not _NUMBER_RE.match(text):
        return text
    return float(text) if "." in text else int(text)


def _row_time(body: dict, ts_field: str) -> Optional[float]:
    raw = body.get(ts_field) if ts_field else None
    if raw in (None, ""):
        return None
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return _epoch(float(raw))
    text = str(raw).strip()
    if _NUMBER_RE.match(text):                 # JSON state files hold epochs as strings
        return _epoch(float(text))
    try:                                       # ISO 8601, with or without a zone
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y"):
        try:
            # A date with no time is midnight UTC, which a browser west of Greenwich
            # draws as the day before. Noon keeps the calendar day right either way.
            return calendar.timegm(time.strptime(text, fmt)) + 43200
        except ValueError:
            continue
    return None


def _epoch(value: float) -> float:
    """Seconds, from seconds or milliseconds. 1e11 is the year 5138 in seconds."""
    return value / 1000 if abs(value) > 1e11 else value


def _name_time(path: Path) -> Optional[float]:
    """The time is in the name: gym_mode_before_1784264441, weekly_summary_20260913."""
    tail = path.stem.rsplit("_", 1)[-1]
    if not tail.isdigit():
        return None
    if len(tail) in (10, 13):
        return _epoch(float(tail))
    if len(tail) == 8:
        try:                                  # a date, so noon — see _row_time
            return calendar.timegm(time.strptime(tail, "%Y%m%d")) + 43200
        except ValueError:
            return None
    return None


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:32]


# ── schedules ────────────────────────────────────────────────────────────────
def _tag_jobs(plan: Plan) -> list[str]:
    """Point every matching schedule at its integration; General takes the rest."""
    from fnmatch import fnmatch

    try:
        from cron.jobs import list_jobs, update_job
    except Exception as exc:
        logger.warning("importer: no cron store to tag: %s", exc)
        return []

    tagged: list[str] = []
    for job in list_jobs(include_disabled=True):
        if (job.get("integration") or "").strip() not in ("", "general"):
            continue
        name = str(job.get("name") or "")
        if plan.space_id == "general":
            matched = not (job.get("integration") or "").strip()
        else:
            matched = any(fnmatch(name, pattern) for pattern in plan.job_patterns)
        if matched:
            update_job(job["id"], {"integration": plan.space_id})
            tagged.append(name or job["id"])
    return tagged


# ── archive, then delete ─────────────────────────────────────────────────────
def _archive_and_remove(workspace: Path, paths: list[Path]) -> Path:
    archive = workspace / f"imported-into-registry-{time.strftime('%Y-%m-%d-%H%M%S')}.tar.gz"
    kept: list[Path] = []
    with tarfile.open(archive, "w:gz") as tar:
        for path in paths:
            try:
                tar.add(path, arcname=str(path.relative_to(workspace)))
                kept.append(path)
            except (OSError, ValueError) as exc:
                logger.warning("importer: %s not archived, so not deleted: %s", path, exc)
    for path in kept:                       # only what made it into the tarball
        try:
            path.unlink()
        except OSError as exc:
            logger.warning("importer: could not remove %s: %s", path, exc)
    return archive


if __name__ == "__main__":  # python -m jarvis_registry.importer /root/workspace [--no-delete]
    import sys

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    argv = [a for a in sys.argv[1:] if not a.startswith("-")]
    outcome = import_all(argv[0] if argv else "/root/workspace",
                         delete="--no-delete" not in sys.argv)
    print(json.dumps(outcome, indent=2))
