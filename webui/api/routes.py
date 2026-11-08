"""
JarvisCopilot Web UI -- Route handlers for GET and POST endpoints.
Extracted from server.py (Sprint 11) so server.py is a thin shell.
"""

import html as _html
import copy
import json
import logging
import os
import queue
import re
import platform
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
import re
from pathlib import Path
from contextlib import closing
from urllib.parse import parse_qs

logger = logging.getLogger(__name__)


# ── Cron run tracking ────────────────────────────────────────────────────────
# Track job IDs currently being executed so the frontend can poll status.
_RUNNING_CRON_JOBS: dict[str, float] = {}  # job_id → start_timestamp
_RUNNING_CRON_LOCK = threading.Lock()
_CRON_OUTPUT_CONTENT_LIMIT = 8000
_CRON_OUTPUT_HEADER_CONTEXT = 200
_CSP_REPORT_LOGGER = logging.getLogger("csp_report")
_CSP_REPORT_RATE_LIMIT: dict[str, list[float]] = {}
_CSP_REPORT_RATE_LIMIT_LOCK = threading.Lock()
_CSP_REPORT_RATE_LIMIT_WINDOW_SECONDS = 60
_CSP_REPORT_RATE_LIMIT_MAX = 100
_CSP_REPORT_MAX_BODY_BYTES = 64 * 1024


from api.profiles import _profiles_match
from api.session_model import clean_session_provider, resolve_session_model_state
from api.chat_turns import turn_options_for_chat, clear_stale_stream_state, _resolve_chat_workspace_with_recovery, start_turn
from api.auth import check_csrf
from api.helpers import serve_file_bytes


def _active_skills_dir() -> Path:
    """Return the skills directory for the request's active JarvisCopilot profile.

    WebUI profile switches are cookie/thread-local scoped, so the agent
    module-level ``tools.skills_tool.SKILLS_DIR`` can still point at the server
    startup profile. Skills UI endpoints must derive the directory from
    ``get_active_hermes_home()`` for every request instead of reading that
    process-global constant.
    """
    try:
        from api.profiles import get_active_hermes_home

        return Path(get_active_hermes_home()) / "skills"
    except Exception:
        try:
            from tools.skills_tool import SKILLS_DIR

            return Path(SKILLS_DIR)
        except Exception:
            return Path(os.getenv("HERMES_HOME", str(Path.home() / ".jarviscopilot"))).expanduser() / "skills"


def _skill_path_within(base_dir: Path, candidate: Path) -> bool:
    try:
        candidate.resolve().relative_to(base_dir.resolve())
        return True
    except (OSError, ValueError):
        return False


def _skill_category_from_path(skill_md: Path, skills_dirs: list[Path]) -> str | None:
    for skills_dir in skills_dirs:
        try:
            rel_path = skill_md.relative_to(skills_dir)
        except ValueError:
            continue
        parts = rel_path.parts
        if len(parts) >= 3:
            return parts[0]
        return None
    return None


def _active_skill_search_dirs(skills_dir: Path) -> list[Path]:
    dirs = [skills_dir]
    try:
        from agent.skill_utils import get_external_skills_dirs

        dirs.extend(Path(p) for p in get_external_skills_dirs())
    except Exception:
        pass
    return [p for p in dirs if p.exists()]


def _skills_list_from_dir(skills_dir: Path, category: str | None = None) -> dict:
    """List skills using an explicit local skills directory.

    This mirrors ``tools.skills_tool.skills_list`` closely, but keeps the local
    scan root explicit so per-client WebUI profile switches do not race on or
    leak through the skills tool's module-global ``SKILLS_DIR``.
    """
    from agent.skill_utils import iter_skill_index_files
    from tools.skills_tool import (
        MAX_DESCRIPTION_LENGTH,
        _EXCLUDED_SKILL_DIRS,
        _get_disabled_skill_names,
        _parse_frontmatter,
        _sort_skills,
        skill_matches_platform,
    )

    if not skills_dir.exists():
        skills_dir.mkdir(parents=True, exist_ok=True)
        return {
            "success": True,
            "skills": [],
            "categories": [],
            "message": f"No skills found. Skills directory created at {skills_dir}/",
        }

    all_skills = []
    seen_names: set[str] = set()
    disabled = _get_disabled_skill_names()
    search_dirs = _active_skill_search_dirs(skills_dir)

    for scan_dir in search_dirs:
        for skill_md in iter_skill_index_files(scan_dir, "SKILL.md"):
            if any(part in _EXCLUDED_SKILL_DIRS for part in skill_md.parts):
                continue
            skill_dir = skill_md.parent
            try:
                content = skill_md.read_text(encoding="utf-8")[:4000]
                frontmatter, body = _parse_frontmatter(content)
                if not skill_matches_platform(frontmatter):
                    continue
                name = frontmatter.get("name", skill_dir.name)[:64]
                if name in seen_names or name in disabled:
                    continue
                description = frontmatter.get("description", "")
                if not description:
                    for line in body.strip().split("\n"):
                        line = line.strip()
                        if line and not line.startswith("#"):
                            description = line
                            break
                if len(description) > MAX_DESCRIPTION_LENGTH:
                    description = description[: MAX_DESCRIPTION_LENGTH - 3] + "..."
                seen_names.add(name)
                all_skills.append(
                    {
                        "name": name,
                        "description": description,
                        "category": _skill_category_from_path(skill_md, search_dirs),
                    }
                )
            except (UnicodeDecodeError, PermissionError) as e:
                logger.debug("Failed to read skill file %s: %s", skill_md, e)
            except Exception as e:
                logger.debug(
                    "Skipping skill at %s: failed to parse: %s", skill_md, e, exc_info=True
                )

    if category:
        all_skills = [s for s in all_skills if s.get("category") == category]
    all_skills = _sort_skills(all_skills)
    categories = sorted(set(s.get("category") for s in all_skills if s.get("category")))
    result = {
        "success": True,
        "skills": all_skills,
        "categories": categories,
        "count": len(all_skills),
    }
    if all_skills:
        result["hint"] = "Use skill_view(name) to see full content, tags, and linked files"
    else:
        result["message"] = "No skills found in skills/ directory."
    return result


def _find_skill_in_dirs(name: str, skills_dirs: list[Path]) -> tuple[Path | None, Path | None]:
    """Resolve a WebUI skill name inside explicit skills directories."""
    from agent.skill_utils import iter_skill_index_files
    from tools.skills_tool import _EXCLUDED_SKILL_DIRS, _parse_frontmatter

    raw_name = str(name or "").strip().strip("/")
    if not raw_name:
        return None, None

    candidate_names = [raw_name]
    if ":" in raw_name:
        namespace, bare = raw_name.split(":", 1)
        if namespace and bare:
            candidate_names.append(f"{namespace}/{bare}")

    for skills_dir in skills_dirs:
        if not skills_dir.exists():
            continue
        for candidate_name in candidate_names:
            direct_path = skills_dir / candidate_name
            if not _skill_path_within(skills_dir, direct_path):
                continue
            if direct_path.is_dir() and (direct_path / "SKILL.md").exists():
                return direct_path, direct_path / "SKILL.md"
            legacy_md = direct_path.with_suffix(".md")
            if legacy_md.exists() and _skill_path_within(skills_dir, legacy_md):
                return legacy_md.parent, legacy_md

        for skill_md in iter_skill_index_files(skills_dir, "SKILL.md"):
            if any(part in _EXCLUDED_SKILL_DIRS for part in skill_md.parts):
                continue
            skill_dir = skill_md.parent
            if skill_dir.name == raw_name:
                return skill_dir, skill_md
            try:
                frontmatter, _ = _parse_frontmatter(skill_md.read_text(encoding="utf-8")[:4000])
                if frontmatter.get("name") == raw_name:
                    return skill_dir, skill_md
            except Exception:
                continue

        for legacy_md in skills_dir.rglob("*.md"):
            if legacy_md.name == "SKILL.md":
                continue
            if legacy_md.stem == raw_name and _skill_path_within(skills_dir, legacy_md):
                return legacy_md.parent, legacy_md
    return None, None


def _find_skill_in_dir(name: str, skills_dir: Path) -> tuple[Path | None, Path | None]:
    """Resolve a WebUI skill name inside an explicit skills directory."""
    return _find_skill_in_dirs(name, [skills_dir])


def _skill_not_found_payload(name: str, skills_dir: Path) -> dict:
    available = [s["name"] for s in _skills_list_from_dir(skills_dir).get("skills", [])[:20]]
    return {
        "success": False,
        "error": f"Skill '{name}' not found.",
        "available_skills": available,
        "hint": "Use skills_list to see all available skills",
    }


def _linked_files_for_skill(skill_dir: Path | None) -> dict:
    if not skill_dir or not (skill_dir / "SKILL.md").exists():
        return {}
    linked_files: dict[str, list[str]] = {}

    references_dir = skill_dir / "references"
    if references_dir.exists():
        refs = [str(f.relative_to(skill_dir)) for f in references_dir.glob("*.md")]
        if refs:
            linked_files["references"] = sorted(refs)

    templates_dir = skill_dir / "templates"
    if templates_dir.exists():
        templates = []
        for ext in ["*.md", "*.py", "*.yaml", "*.yml", "*.json", "*.tex", "*.sh"]:
            templates.extend(str(f.relative_to(skill_dir)) for f in templates_dir.rglob(ext))
        if templates:
            linked_files["templates"] = sorted(set(templates))

    assets_dir = skill_dir / "assets"
    if assets_dir.exists():
        assets = [str(f.relative_to(skill_dir)) for f in assets_dir.rglob("*") if f.is_file()]
        if assets:
            linked_files["assets"] = sorted(assets)

    scripts_dir = skill_dir / "scripts"
    if scripts_dir.exists():
        scripts = []
        for ext in ["*.py", "*.sh", "*.bash", "*.js", "*.ts", "*.rb"]:
            scripts.extend(str(f.relative_to(skill_dir)) for f in scripts_dir.glob(ext))
        if scripts:
            linked_files["scripts"] = sorted(set(scripts))

    return linked_files


def _skill_view_from_file(skill_dir: Path | None, skill_md: Path) -> dict:
    from tools.skills_tool import _parse_frontmatter, _parse_tags, skill_matches_platform

    content = skill_md.read_text(encoding="utf-8")
    frontmatter, _body = _parse_frontmatter(content)
    if not skill_matches_platform(frontmatter):
        return {"success": False, "error": "Skill is not available on this platform."}

    metadata = frontmatter.get("metadata")
    # Prefer jarviscopilot namespace; fall back to legacy `jarviscopilot` for compat.
    hermes_meta = (metadata.get("jarviscopilot") or metadata.get("jarviscopilot") or {}) if isinstance(metadata, dict) else {}
    tags = _parse_tags(hermes_meta.get("tags") or frontmatter.get("tags", ""))
    related_skills = _parse_tags(
        hermes_meta.get("related_skills") or frontmatter.get("related_skills", "")
    )
    try:
        path = str(skill_md.relative_to((skill_dir or skill_md.parent).parent))
    except ValueError:
        path = str(skill_md)

    return {
        "success": True,
        "name": frontmatter.get("name", skill_md.stem if not skill_dir else skill_dir.name),
        "description": frontmatter.get("description", ""),
        "tags": tags,
        "related_skills": related_skills,
        "content": content,
        "path": path,
        "skill_dir": str(skill_dir) if skill_dir else None,
        "linked_files": _linked_files_for_skill(skill_dir),
    }


def _skill_view_from_active_dir(name: str) -> dict:
    from tools.skills_tool import skill_view as _skill_view

    skills_dir = _active_skills_dir()
    search_dirs = _active_skill_search_dirs(skills_dir)
    skill_dir, skill_md = _find_skill_in_dirs(name, search_dirs)
    if not skill_md:
        # Preserve plugin-qualified skill viewing without falling back to the
        # startup/root profile's local skills tree for ordinary missing skills.
        if ":" in str(name or ""):
            try:
                from agent.skill_utils import is_valid_namespace, parse_qualified_name
                from jarviscopilot_cli.plugins import discover_plugins, get_plugin_manager

                namespace, _bare = parse_qualified_name(name)
                if is_valid_namespace(namespace):
                    discover_plugins()
                    pm = get_plugin_manager()
                    if pm.find_plugin_skill(name) is not None or pm.list_plugin_skills(namespace):
                        raw = _skill_view(name)
                        return json.loads(raw) if isinstance(raw, str) else raw
            except Exception:
                pass
        return _skill_not_found_payload(name, skills_dir)
    return _skill_view_from_file(skill_dir, skill_md)

# ── SSE app-level heartbeat (#1623) ────────────────────────────────────────
#
# Kernel TCP keepalive (server.py setsockopt block) declares a peer dead at
# KEEPIDLE (10s) + KEEPINTVL (5s) * KEEPCNT (3) = 25s in the worst case. The
# app-level SSE heartbeat must fire well below that window so flaky-network
# probes never get the chance to kill an idle stream during long LLM thinking
# phases. 5s gives the kernel ~5x headroom: probe at 10s, heartbeat byte at
# every 5s of idle keeps the socket warm.
#
# Cost: ~12 bytes per heartbeat * 12 extra heartbeats/min = ~150B/min idle.
# Trivial; many production SSE deployments run 5-15s heartbeats specifically
# to handle proxies and mobile NAT.


def _mark_cron_running(job_id: str):
    with _RUNNING_CRON_LOCK:
        _RUNNING_CRON_JOBS[job_id] = time.time()


def _mark_cron_done(job_id: str):
    with _RUNNING_CRON_LOCK:
        _RUNNING_CRON_JOBS.pop(job_id, None)


def _is_cron_running(job_id: str) -> tuple[bool, float]:
    """Return (is_running, elapsed_seconds)."""
    with _RUNNING_CRON_LOCK:
        t = _RUNNING_CRON_JOBS.get(job_id)
        if t is None:
            return False, 0.0
        return True, time.time() - t


def _cron_response_marker_index(text: str) -> int:
    """Return the start index of a markdown Response heading, if present."""
    candidates = []
    for heading in ("## Response", "# Response"):
        if text.startswith(heading):
            candidates.append(0)
        idx = text.find(f"\n{heading}")
        if idx >= 0:
            candidates.append(idx + 1)
    return min(candidates) if candidates else -1


def _cron_output_content_window(text: str, limit: int = _CRON_OUTPUT_CONTENT_LIMIT) -> str:
    """Return a bounded cron output window that preserves useful response text.

    Cron output files can contain large skill dumps in the Prompt section. The
    UI already extracts ``## Response`` when present, so keep that section in
    the API payload instead of blindly returning the first ``limit`` chars.
    """
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text

    response_idx = _cron_response_marker_index(text)
    if response_idx >= 0:
        header = text[:min(_CRON_OUTPUT_HEADER_CONTEXT, response_idx)].rstrip()
        response = text[response_idx:].lstrip("\n")
        content = f"{header}\n...\n{response}" if header else response
        return content[:limit]

    return text[-limit:]


def _cron_harness_names():
    """``{id: name}`` of the active profile's harnesses (None when unreadable)."""
    try:
        from api.harness_store import store_for_request

        return store_for_request().names()
    except Exception:
        logger.debug("cron: harness list unavailable", exc_info=True)
        return None


def _cron_job_for_api(job: dict, harness_names=None) -> dict:
    """Return a cron job payload with optional UI settings normalized.

    ``runs_on`` says what the schedule runs on — ``{kind: default|model|harness,
    label, value}`` (``value`` is the editor choice: ``default``,
    ``model:@provider:model`` or ``harness:<id>``). Schedules no longer carry a
    per-job profile.

    ``toast_notifications`` is a WebUI preference for completion toasts. Legacy
    jobs default to enabled so existing behavior is preserved unless a job is
    explicitly muted.
    """
    payload = dict(job or {})
    payload.pop("profile", None)
    payload["toast_notifications"] = payload.get("toast_notifications") is not False
    try:
        from cron.jobs import runs_on

        names = harness_names if harness_names is not None else _cron_harness_names()
        payload["runs_on"] = runs_on(payload, harness_names=names)
    except Exception:
        logger.debug("cron: runs_on summary unavailable", exc_info=True)
    return payload


def _cron_jobs_for_api(jobs) -> list[dict]:
    names = _cron_harness_names()
    return [_cron_job_for_api(job, names) for job in (jobs or [])]


def _cron_runs_on_fields(body: dict, current_harness_id=None) -> dict:
    """``model`` / ``provider`` / ``harness_id`` from a create or update body.

    A key that is present is passed on even when null or "", so an editor can
    clear it (Default = all three cleared). An unknown harness raises
    ValueError — unless it is the one the job already has (``current_harness_id``):
    an edit of a job whose harness was deleted resends it, and the run falls
    back to Default anyway.
    """
    out = {}
    for key in ("model", "provider", "harness_id"):
        if key in body:
            value = body.get(key)
            out[key] = str(value).strip() if value is not None else None
    harness_id = out.get("harness_id")
    if harness_id and harness_id != (current_harness_id or None):
        names = _cron_harness_names()
        if names is not None and harness_id not in names:
            raise ValueError(f"Unknown harness: {harness_id}")
    return out


def _cron_job_subprocess_main(job, cron_home, result_queue):
    """Run one cron job inside a child process pinned to its store owner's home.

    A harness run's after-node results (``job["_after_deliveries"]``) travel
    back with the result so the parent delivers them after the answer."""
    try:
        def _run():
            from cron.scheduler import run_job

            return run_job(job)

        if cron_home is None:
            result = _run()
        else:
            from api.profiles import cron_profile_context_for_home

            with cron_profile_context_for_home(cron_home):
                result = _run()
        result_queue.put(("ok", result, list(job.get("_after_deliveries") or [])))
    except BaseException as exc:  # pragma: no cover - surfaced in parent
        import traceback

        result_queue.put(("error", f"{type(exc).__name__}: {exc}", traceback.format_exc()))


def _cron_subprocess_result_timeout_seconds(job):
    """Return how long the manual-run parent waits for child result payloads."""
    for key in ("timeout_seconds", "max_runtime_seconds", "timeout"):
        raw = (job or {}).get(key)
        if raw in (None, ""):
            continue
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if value > 0:
            return max(60.0, value + 30.0)
    # Manual cron jobs can legitimately run for a long time.  Keep a recovery
    # path for wedged children without truncating normal long-running jobs.
    return 6 * 60 * 60.0


def _run_cron_job_in_profile_subprocess(job, cron_home):
    """Execute cron.scheduler.run_job without holding the parent cron env lock.

    cron.scheduler/cron.jobs still rely on process-global HERMES_HOME and module
    constants, so running the job body in a child process gives each long cron
    execution its own globals. The parent process only uses cron_profile_context
    for short metadata reads/writes and remains responsive to unrelated cron UI
    and API calls while the job runs.
    """
    import multiprocessing
    import queue

    ctx = multiprocessing.get_context("spawn")
    result_queue = ctx.Queue(maxsize=1)
    process = ctx.Process(
        target=_cron_job_subprocess_main,
        args=(job, cron_home, result_queue),
    )
    process.start()

    result_timeout = _cron_subprocess_result_timeout_seconds(job)
    status = "error"
    payload = ["cron run subprocess failed before producing a result", ""]
    try:
        try:
            # Drain the potentially large pickled result before joining.  If the
            # child puts >~64 KiB on a multiprocessing.Queue, joining first can
            # deadlock while the child's feeder thread waits for the parent to
            # read from the pipe.
            status, *payload = result_queue.get(timeout=result_timeout)
        except queue.Empty:
            status = "error"
            if process.is_alive():
                process.terminate()
                process.join(timeout=5)
                payload = [
                    f"cron run subprocess produced no result within {result_timeout:g}s and was terminated",
                    "",
                ]
            else:
                payload = [
                    f"cron run subprocess exited with code {process.exitcode} without producing a result",
                    "",
                ]
        finally:
            process.join(timeout=5)
            if process.is_alive():
                process.terminate()
                process.join(timeout=5)
                if status == "ok":
                    status = "error"
                    payload = [
                        "cron run subprocess did not exit after returning a result",
                        "",
                    ]
    finally:
        result_queue.close()
        result_queue.join_thread()

    if status == "ok":
        if len(payload) > 1 and payload[1]:
            job["_after_deliveries"] = list(payload[1])
        return payload[0]

    message = payload[0]
    traceback_text = payload[1] if len(payload) > 1 else ""
    if traceback_text:
        logger.error("Manual cron subprocess failed:\n%s", traceback_text)
    raise RuntimeError(message)


def _run_cron_tracked(job, profile_home=None):
    """Wrapper that tracks running state around cron.scheduler.run_job.

    ``profile_home`` is the cron store that owns the job: the run reads its
    config/.env, and the job row/output metadata are written back there. What
    the job runs on (Default, a model, a harness) is the job's own setting.
    """
    import importlib

    from cron.jobs import mark_job_run, save_job_output

    _cron_scheduler = importlib.import_module("cron.scheduler")

    _silent_marker = getattr(_cron_scheduler, "SILENT_MARKER", "[SILENT]")
    _deliver_result = getattr(_cron_scheduler, "_deliver_result", None)
    _deliver_after_results = getattr(_cron_scheduler, "deliver_after_results", None)

    job_id = job.get("id", "")

    def _with_cron_home(home, fn):
        if home is None:
            return fn()
        from api.profiles import cron_profile_context_for_home

        with cron_profile_context_for_home(home):
            return fn()

    try:
        success, output, final_response, error = _run_cron_job_in_profile_subprocess(
            job, profile_home
        )

        # Persist output, deliver the same content the scheduled cron path would
        # send (a harness run's after-node results follow the answer), and write
        # run metadata back to the job's owning cron store.
        def _persist_success():
            save_job_output(job_id, output)

            deliver_content = (
                final_response
                if success
                else f"⚠️ Cron job '{job.get('name', job_id)}' failed:\n{error}"
            )
            should_deliver = bool(deliver_content)
            if should_deliver and success and _silent_marker in deliver_content.strip().upper():
                should_deliver = False

            delivery_error = None
            if should_deliver and _deliver_result is not None:
                try:
                    delivery_error = _deliver_result(job, deliver_content)
                except Exception as de:
                    delivery_error = str(de)
                    logger.error("Delivery failed for manual cron job %s: %s", job_id, de)
            if success and _deliver_after_results is not None:
                try:
                    delivery_error = _deliver_after_results(job) or delivery_error
                except Exception as de:
                    delivery_error = delivery_error or str(de)
                    logger.error("After-node delivery failed for manual cron job %s: %s", job_id, de)

            # Match the scheduled cron path: an apparently successful run with no
            # final response should not leave the job looking healthy.
            _success, _error = success, error
            if _success and not final_response:
                _success = False
                _error = "Agent completed but produced empty response (model error, timeout, or misconfiguration)"

            try:
                mark_job_run(job_id, _success, _error, delivery_error=delivery_error)
            except TypeError:
                # Older/fake cron.jobs modules used by focused WebUI tests may
                # not expose the newer delivery_error parameter. Real JarvisCopilot
                # scheduler builds do, so this is only a compatibility shim for
                # legacy test doubles and deployments.
                mark_job_run(job_id, _success, _error)

        _with_cron_home(profile_home, _persist_success)
    except Exception as e:
        logger.exception("Manual cron run failed for job %s", job_id)
        try:
            _with_cron_home(profile_home, lambda: mark_job_run(job_id, False, str(e)))
        except Exception:
            logger.debug("Failed to mark manual cron run failure for %s", job_id)
    finally:
        _mark_cron_done(job_id)


# OpenAI-compatible /v1/models endpoints for live model discovery.
# Used as fallback when jarviscopilot_cli.provider_model_ids() is unavailable or
# returns [] for a provider (#871).  Kept at module level so the dict is
# built once, not reconstructed per request.
_OPENAI_COMPAT_ENDPOINTS = {
    "zai": "https://api.z.ai/v1",
    "minimax": "https://api.minimax.chat/v1",
    "mistralai": "https://api.mistral.ai/v1",
    "xai": "https://api.x.ai/v1",
    "deepseek": "https://api.deepseek.com",
    "gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
    "nvidia": "https://integrate.api.nvidia.com/v1",
}
# NOTE: "openai-codex" is excluded because it maps to the same endpoint as
# the base "openai" provider (api.openai.com/v1).  When both are configured
# the openai provider is already wired through provider_model_ids(); codex-
# specific model filtering happens downstream in jarviscopilot_cli.
#
_LIVE_MODELS_CACHE_TTL = 60.0
_LIVE_MODELS_CACHE: dict[tuple[str, str], tuple[float, dict]] = {}
_LIVE_MODELS_CACHE_LOCK = threading.RLock()


def _active_profile_for_live_models_cache() -> str:
    try:
        from api.profiles import get_active_profile_name

        return get_active_profile_name() or "default"
    except Exception as _e:
        # A transient profile-resolution error mis-scopes the cache for up to
        # 60s ("default" gets the wrong payload). Log so we can detect it; the
        # blast radius stays small because the TTL caps the bad-cache window.
        logger.debug("_active_profile_for_live_models_cache fell back to 'default': %s", _e)
        return "default"


def _live_models_cache_key(provider: str) -> tuple[str, str]:
    return (_active_profile_for_live_models_cache(), provider)


def _get_cached_live_models(key: tuple[str, str]) -> dict | None:
    now = time.monotonic()
    with _LIVE_MODELS_CACHE_LOCK:
        cached = _LIVE_MODELS_CACHE.get(key)
        if not cached:
            return None
        ts, payload = cached
        if now - ts >= _LIVE_MODELS_CACHE_TTL:
            _LIVE_MODELS_CACHE.pop(key, None)
            return None
        return copy.deepcopy(payload)


def _set_cached_live_models(key: tuple[str, str], payload: dict) -> None:
    with _LIVE_MODELS_CACHE_LOCK:
        _LIVE_MODELS_CACHE[key] = (time.monotonic(), copy.deepcopy(payload))


def _clear_live_models_cache() -> None:
    with _LIVE_MODELS_CACHE_LOCK:
        _LIVE_MODELS_CACHE.clear()

from api.config import (
    SESSION_DIR,
    SESSIONS,
    STREAMS,
    STREAMS_LOCK,
    STREAM_LAST_EVENT_ID,
    SERVER_START_TIME,
    _resolve_cli_toolsets,
    _INDEX_HTML_PATH,
    get_available_models,
    MIME_MAP,
    MAX_UPLOAD_BYTES,
    CHAT_LOCK,
    _get_session_agent_lock,
    load_settings,
    save_settings,
    set_hermes_default_model,
    model_with_provider_context,
    get_reasoning_status,
    set_reasoning_display,
    set_reasoning_effort,
    create_stream_channel,
)
from api.helpers import (
    require,
    bad,
    safe_resolve,
    j,
    t,
    _security_headers,
    _sanitize_error,
    _redact_text,
    answers_http_errors,
    need,
    query_sid,
)
from api.agent_health import build_agent_health_payload
from api import sse
from api.mounts import Request, dispatch as dispatch_mount
from api.profiles import get_active_hermes_home
from api.request_diagnostics import RequestDiagnostics
from api.system_health import build_system_health_payload
from api.session_routes import (
    _all_profiles_query_flag,
    _gateway_session_metadata_path,
    _load_gateway_session_identity_map,
    _normalize_messaging_source,
    _run_journal_status_payload,
    session_or_404,
)


# ── CSRF: validate Origin/Referer on POST ────────────────────────────────────


def _client_ip_for_rate_limit(handler) -> str:
    try:
        address = getattr(handler, "client_address", None)
        if address:
            return str(address[0])
    except Exception:
        pass
    return "unknown"


def _csp_report_rate_limited(handler, *, now: float | None = None) -> bool:
    now = time.time() if now is None else now
    key = _client_ip_for_rate_limit(handler)
    cutoff = now - _CSP_REPORT_RATE_LIMIT_WINDOW_SECONDS
    with _CSP_REPORT_RATE_LIMIT_LOCK:
        timestamps = [ts for ts in _CSP_REPORT_RATE_LIMIT.get(key, []) if ts >= cutoff]
        if len(timestamps) >= _CSP_REPORT_RATE_LIMIT_MAX:
            _CSP_REPORT_RATE_LIMIT[key] = timestamps
            return True
        timestamps.append(now)
        _CSP_REPORT_RATE_LIMIT[key] = timestamps
    return False


def _send_no_content(handler, status: int = 204) -> bool:
    handler.send_response(status)
    handler.send_header("Content-Length", "0")
    handler.end_headers()
    return True


def _read_csp_report_payload(handler):
    try:
        length = int(handler.headers.get("Content-Length", 0))
    except Exception:
        length = 0
    if length > _CSP_REPORT_MAX_BODY_BYTES:
        try:
            handler.rfile.read(_CSP_REPORT_MAX_BODY_BYTES)
        except Exception:
            pass
        return {"discarded": "body_too_large", "bytes": length}
    raw = handler.rfile.read(length) if length else b"{}"
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {"invalid": True, "bytes": len(raw)}


def _handle_csp_report(handler) -> bool:
    """Collect browser CSP report-only violations without requiring auth."""
    if _csp_report_rate_limited(handler):
        _CSP_REPORT_LOGGER.warning(
            "Dropped CSP report from %s: rate limit exceeded",
            _client_ip_for_rate_limit(handler),
        )
        return _send_no_content(handler)

    payload = _read_csp_report_payload(handler)
    _CSP_REPORT_LOGGER.info("CSP report from %s: %s", _client_ip_for_rate_limit(handler), payload)
    return _send_no_content(handler)


def _normalize_session_model_in_place(session) -> str:
    original_model = getattr(session, "model", None) or ""
    original_provider = clean_session_provider(
        getattr(session, "model_provider", None)
    )
    effective_model, effective_provider, changed = resolve_session_model_state(
        original_model or None,
        original_provider,
    )
    provider_changed = effective_provider != original_provider
    # Only persist the correction if the session had an explicit model that needed changing.
    # Sessions with no model stored (empty/None) get the effective default returned without
    # a disk write — no need to rebuild the index for a fill-in-blank operation.
    if original_model and effective_model and (
        (changed and original_model != effective_model) or provider_changed
    ):
        if changed and original_model != effective_model:
            session.model = effective_model
        session.model_provider = effective_provider
        session.save(touch_updated_at=False)
    return effective_model


# Cross-device mirror: the per-session announcement channel that tells every
# device with this chat open that a run started elsewhere. See api/session_events.
from api.session_events import SESSION_EVENTS
from api.models import (
    Session,
    get_session,
    all_sessions,
    title_from,
    SESSION_INDEX_FILE,
    _active_state_db_path,
    load_projects,
    save_projects,
    get_cli_sessions,
)
from api.workspace import (
    load_workspaces,
    save_workspaces,
    get_last_workspace,
    list_dir,
    list_workspace_suggestions,
    read_file_content,
    resolve_trusted_workspace,
    validate_workspace_to_add,
    _is_blocked_system_path,
    _strip_surrounding_quotes,
)
from api.upload import handle_upload, handle_upload_extract, handle_transcribe
from api.streaming import _run_agent_streaming, cancel_stream
from api.run_journal import (
    find_run_summary,
    read_run_events,
    stale_interrupted_event,
)
from api.providers import get_providers, get_provider_quota, get_all_provider_quota, get_provider_cost_history, set_provider_key, remove_provider_key
from api.onboarding import (
    apply_onboarding_setup,
    get_onboarding_status,
    complete_onboarding,
    probe_provider_endpoint,
)
from api.oauth import (
    cancel_onboarding_oauth_flow,
    poll_onboarding_oauth_flow,
    start_onboarding_oauth_flow,
)

# ── Login page locale strings ─────────────────────────────────────────────────
# Add entries here to support more languages on the login page.
# The key must match the 'language' setting value (from static/i18n.js LOCALES).
_LOGIN_LOCALE = {
    "en": {
        "lang": "en",
        "title": "Sign in",
        "subtitle": "Enter your password to continue",
        "placeholder": "Password",
        "btn": "Sign in",
        "invalid_pw": "Invalid password",
        "conn_failed": "Connection failed",
    },
    "fr": {
        "lang": "fr-FR",
        "title": "Se connecter",
        "subtitle": "Entrez votre mot de passe pour continuer",
        "placeholder": "Mot de passe",
        "btn": "Se connecter",
        "invalid_pw": "Mot de passe invalide",
        "conn_failed": "\u00c9chec de la connexion",
    },
    "es": {
        "lang": "es-ES",
        "title": "Iniciar sesi\u00f3n",
        "subtitle": "Introduce tu contrase\u00f1a para continuar",
        "placeholder": "Contrase\u00f1a",
        "btn": "Entrar",
        "invalid_pw": "Contrase\u00f1a inv\u00e1lida",
        "conn_failed": "Error de conexi\u00f3n",
    },
    "de": {
        "lang": "de-DE",
        "title": "Anmelden",
        "subtitle": "Geben Sie Ihr Passwort ein, um fortzufahren",
        "placeholder": "Passwort",
        "btn": "Anmelden",
        "invalid_pw": "Ung\u00fcltiges Passwort",
        "conn_failed": "Verbindung fehlgeschlagen",
    },
    "ru": {
        "lang": "ru-RU",
        "title": "\u0412\u043e\u0439\u0442\u0438",
        "subtitle": "\u0412\u0432\u0435\u0434\u0438\u0442\u0435 \u043f\u0430\u0440\u043e\u043b\u044c, \u0447\u0442\u043e\u0431\u044b \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0438\u0442\u044c",
        "placeholder": "\u041f\u0430\u0440\u043e\u043b\u044c",
        "btn": "\u0412\u043e\u0439\u0442\u0438",
        "invalid_pw": "\u041d\u0435\u0432\u0435\u0440\u043d\u044b\u0439 \u043f\u0430\u0440\u043e\u043b\u044c",
        "conn_failed": "\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c\u0441\u044f",
    },
    "zh": {
        "lang": "zh-CN",
        "title": "\u767b\u5f55",
        "subtitle": "\u8f93\u5165\u5bc6\u7801\u7ee7\u7eed\u4f7f\u7528",
        "placeholder": "\u5bc6\u7801",
        "btn": "\u767b\u5f55",
        "invalid_pw": "\u5bc6\u7801\u9519\u8bef",
        "conn_failed": "\u8fde\u63a5\u5931\u8d25",
    },
    "zh-Hant": {
        "lang": "zh-TW",
        "title": "\u767b\u5f55",
        "subtitle": "\u8f38\u5165\u5bc6\u78bc\u7e7c\u7e8c\u4f7f\u7528",
        "placeholder": "\u5bc6\u78bc",
        "btn": "\u767b\u5f55",
        "invalid_pw": "\u5bc6\u78bc\u932f\u8aa4",
        "conn_failed": "\u9023\u63a5\u5931\u6557",
    },
    # Strings mirror static/i18n.js login_* keys for the corresponding locale.
    # See issue #1442. When adding a new locale to LOCALES in i18n.js, also add
    # the matching entry here — tests/test_login_locale_parity.py enforces this.
    "it": {
        "lang": "it-IT",
        "title": "Accedi",
        "subtitle": "Inserisci la password per continuare",
        "placeholder": "Password",
        "btn": "Accedi",
        "invalid_pw": "Password non valida",
        "conn_failed": "Connessione fallita",
    },
    "ja": {
        "lang": "ja-JP",
        "title": "\u30b5\u30a4\u30f3\u30a4\u30f3",
        "subtitle": "\u30d1\u30b9\u30ef\u30fc\u30c9\u3092\u5165\u529b\u3057\u3066\u7d9a\u884c",
        "placeholder": "\u30d1\u30b9\u30ef\u30fc\u30c9",
        "btn": "\u30b5\u30a4\u30f3\u30a4\u30f3",
        "invalid_pw": "\u30d1\u30b9\u30ef\u30fc\u30c9\u304c\u7121\u52b9\u3067\u3059",
        "conn_failed": "\u63a5\u7d9a\u5931\u6557",
    },
    "pt": {
        "lang": "pt-BR",
        "title": "Entrar",
        "subtitle": "Digite sua senha para continuar",
        "placeholder": "Senha",
        "btn": "Entrar",
        "invalid_pw": "Senha inv\u00e1lida",
        "conn_failed": "Falha na conex\u00e3o",
    },
    "ko": {
        "lang": "ko-KR",
        "title": "\ub85c\uadf8\uc778",
        "subtitle": "\uacc4\uc18d\ud558\ub824\uba74 \ube44\ubc00\ubc88\ud638\ub97c \uc785\ub825\ud558\uc138\uc694",
        "placeholder": "\ube44\ubc00\ubc88\ud638",
        "btn": "\ub85c\uadf8\uc778",
        "invalid_pw": "\ube44\ubc00\ubc88\ud638\uac00 \uc62c\ubc14\ub974\uc9c0 \uc54a\uc2b5\ub2c8\ub2e4",
        "conn_failed": "\uc5f0\uacb0 \uc2e4\ud328",
    },
}


def _resolve_login_locale_key(raw_lang: str | None) -> str:
    """Resolve settings.language to a known _LOGIN_LOCALE key."""
    if not raw_lang:
        return "en"
    lang = str(raw_lang).strip()
    if not lang:
        return "en"
    if lang in _LOGIN_LOCALE:
        return lang

    normalized = lang.replace("_", "-")
    lower = normalized.lower()

    # Case-insensitive direct key match first.
    for key in _LOGIN_LOCALE:
        if key.lower() == lower:
            return key

    # Common Chinese aliases.
    if lower == "zh" or lower.startswith("zh-cn") or lower.startswith("zh-sg") or lower.startswith("zh-hans"):
        return "zh"
    if lower.startswith("zh-tw") or lower.startswith("zh-hk") or lower.startswith("zh-mo") or lower.startswith("zh-hant"):
        return "zh-Hant" if "zh-Hant" in _LOGIN_LOCALE else "zh"

    # Fallback to base language subtag (e.g. en-US -> en).
    base = lower.split("-", 1)[0]
    for key in _LOGIN_LOCALE:
        if key.lower() == base:
            return key
    return "en"

# ── Login page (self-contained, no external deps) ────────────────────────────
_LOGIN_PAGE_HTML = """<!doctype html>
<html lang="{{LANG}}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{BOT_NAME}} — {{LOGIN_TITLE}}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#1a1a2e;color:#e8e8f0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  height:100vh;display:flex;align-items:center;justify-content:center}
.card{background:#16213e;border:1px solid rgba(255,255,255,.08);border-radius:16px;padding:36px 32px;
  width:320px;text-align:center;box-shadow:0 8px 32px rgba(0,0,0,.3)}
.logo{width:48px;height:48px;border-radius:12px;background:linear-gradient(145deg,#e8a030,#e94560);
  display:flex;align-items:center;justify-content:center;font-weight:800;font-size:20px;color:#fff;
  margin:0 auto 12px;box-shadow:0 2px 12px rgba(233,69,96,.3)}
h1{font-size:18px;font-weight:600;margin-bottom:4px}
.sub{font-size:12px;color:#8888aa;margin-bottom:24px}
input{width:100%;padding:10px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.1);
  background:rgba(255,255,255,.04);color:#e8e8f0;font-size:14px;outline:none;margin-bottom:14px;
  transition:border-color .15s}
input:focus{border-color:rgba(124,185,255,.5);box-shadow:0 0 0 3px rgba(124,185,255,.1)}
button{width:100%;padding:10px;border-radius:10px;border:none;background:rgba(124,185,255,.15);
  border:1px solid rgba(124,185,255,.3);color:#7cb9ff;font-size:14px;font-weight:600;cursor:pointer;
  transition:all .15s}
button:hover{background:rgba(124,185,255,.25)}
.err{color:#e94560;font-size:12px;margin-top:10px;display:none}
</style></head><body>
<div class="card">
  <div class="logo">{{BOT_NAME_INITIAL}}</div>
  <h1>{{BOT_NAME}}</h1>
  <p class="sub">{{LOGIN_SUBTITLE}}</p>
  <form id="login-form" data-invalid-pw="{{LOGIN_INVALID_PW}}" data-conn-failed="{{LOGIN_CONN_FAILED}}">
    <input type="password" id="pw" placeholder="{{LOGIN_PLACEHOLDER}}" autofocus>
    <button type="submit">{{LOGIN_BTN}}</button>
  </form>
  <div class="err" id="err"></div>
</div>
<!-- Keep login.js relative so subpath mounts load it under the current scope. -->
<script src="static/login.js?v={{WEBUI_VERSION}}"></script>
</body></html>"""


# ── Pair page (JarvisCopilot device pairing) ─────────────────────────────────
# Self-contained like the login page so a fresh device can pair without any
# external asset requests (which would 401 in pairing-required mode anyway).
_PAIR_PAGE_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>JarvisCopilot — Pair this device</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0e1626;color:#e8e8f0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:#14203a;border:1px solid rgba(255,255,255,.08);border-radius:18px;padding:36px 32px;
  width:360px;max-width:100%;box-shadow:0 20px 60px rgba(0,0,0,.45)}
.logo{width:56px;height:56px;border-radius:14px;background:linear-gradient(145deg,#f0b341,#e0552b);
  display:flex;align-items:center;justify-content:center;font-weight:800;font-size:22px;color:#fff;
  margin:0 auto 14px;box-shadow:0 6px 24px rgba(224,85,43,.35);letter-spacing:.5px}
h1{font-size:20px;font-weight:600;text-align:center;margin-bottom:6px}
.sub{font-size:13px;color:#9aa1bd;text-align:center;margin-bottom:22px;line-height:1.5}
.code-row{display:flex;gap:6px;justify-content:center;margin-bottom:14px}
.code-row input{width:38px;height:46px;text-align:center;font-size:22px;font-weight:700;letter-spacing:.5px;
  border-radius:10px;border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.05);
  color:#e8e8f0;outline:none;text-transform:uppercase;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.code-row input:focus{border-color:rgba(240,179,65,.55);box-shadow:0 0 0 3px rgba(240,179,65,.18)}
.dash{align-self:center;color:#9aa1bd;font-weight:700;padding:0 4px}
label{display:block;font-size:12px;color:#9aa1bd;margin-top:14px;margin-bottom:6px}
input.name{width:100%;padding:10px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.1);
  background:rgba(255,255,255,.04);color:#e8e8f0;font-size:14px;outline:none}
input.name:focus{border-color:rgba(124,185,255,.5);box-shadow:0 0 0 3px rgba(124,185,255,.1)}
button{width:100%;padding:12px;margin-top:18px;border-radius:10px;border:none;
  background:linear-gradient(145deg,#f0b341,#e0552b);color:#fff;font-size:14px;font-weight:700;
  cursor:pointer;transition:filter .15s,transform .05s;letter-spacing:.3px}
button:hover{filter:brightness(1.06)}
button:active{transform:translateY(1px)}
button[disabled]{filter:grayscale(.4) brightness(.7);cursor:not-allowed}
.msg{margin-top:14px;font-size:13px;text-align:center;min-height:18px}
.msg.err{color:#ff7a8a}
.msg.ok{color:#7ae597}
.hint{margin-top:18px;font-size:11px;color:#6b7390;text-align:center;line-height:1.6}
.hint code{background:rgba(255,255,255,.06);padding:2px 6px;border-radius:6px;color:#cdd3ec}
</style></head><body>
<div class="card">
  <div class="logo">JC</div>
  <h1>Pair this device</h1>
  <p class="sub">Enter the 6-character code shown by <code style="background:rgba(255,255,255,.06);padding:2px 6px;border-radius:6px">jarviscopilot pair</code> on the host.</p>
  <form id="pair-form" autocomplete="off">
    <div class="code-row">
      <input class="c" id="c0" maxlength="1" inputmode="latin" autocapitalize="characters" autofocus>
      <input class="c" id="c1" maxlength="1" inputmode="latin" autocapitalize="characters">
      <input class="c" id="c2" maxlength="1" inputmode="latin" autocapitalize="characters">
      <span class="dash">&minus;</span>
      <input class="c" id="c3" maxlength="1" inputmode="latin" autocapitalize="characters">
      <input class="c" id="c4" maxlength="1" inputmode="latin" autocapitalize="characters">
      <input class="c" id="c5" maxlength="1" inputmode="latin" autocapitalize="characters">
    </div>
    <label for="name">Device name (optional)</label>
    <input class="name" id="name" placeholder="e.g. Pranav's iPhone" maxlength="48">
    <button type="submit" id="submit">Pair</button>
    <div id="msg" class="msg"></div>
  </form>
  <div class="hint">After pairing, this device gets a long-lived session cookie. Revoke anytime from the Devices tab.</div>
</div>
<script>
(function(){
  const inputs=[...document.querySelectorAll('.c')];
  inputs.forEach((el,i)=>{
    el.addEventListener('input',()=>{
      el.value=el.value.toUpperCase().replace(/[^A-Z0-9]/g,'');
      if(el.value && i<inputs.length-1) inputs[i+1].focus();
    });
    el.addEventListener('keydown',ev=>{
      if(ev.key==='Backspace' && !el.value && i>0){inputs[i-1].focus();}
    });
    el.addEventListener('paste',ev=>{
      const txt=(ev.clipboardData||window.clipboardData).getData('text')||'';
      const cleaned=txt.toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,6);
      if(cleaned.length){
        ev.preventDefault();
        for(let k=0;k<6;k++) inputs[k].value=cleaned[k]||'';
        inputs[Math.min(cleaned.length,5)].focus();
      }
    });
  });
  const msg=document.getElementById('msg');
  const btn=document.getElementById('submit');
  document.getElementById('pair-form').addEventListener('submit', async ev=>{
    ev.preventDefault();
    const code=inputs.map(e=>e.value).join('');
    if(code.length!==6){msg.className='msg err';msg.textContent='Enter all 6 characters.';return;}
    btn.disabled=true;
    msg.className='msg';msg.textContent='Pairing...';
    try{
      const res=await fetch('/api/auth/pair/claim',{
        method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({code, name: document.getElementById('name').value})
      });
      const data=await res.json().catch(()=>({}));
      if(res.ok && data.ok){
        msg.className='msg ok';msg.textContent='Paired. Loading...';
        const url=new URL(window.location.href);
        const next=url.searchParams.get('next')||'/';
        setTimeout(()=>{window.location.href=next;},400);
      }else{
        btn.disabled=false;
        msg.className='msg err';
        msg.textContent=(data && data.error) || 'Invalid or expired code.';
      }
    }catch(e){
      btn.disabled=false;
      msg.className='msg err';msg.textContent='Network error. Try again.';
    }
  });
})();
</script>
</body></html>"""


# ── Logs endpoint ─────────────────────────────────────────────────────────────
_LOG_FILE_WHITELIST = {
    "agent": "agent.log",
    "errors": "errors.log",
    "gateway": "gateway.log",
}
_LOG_TAIL_VALUES = {100, 200, 500, 1000}
_LOG_DEFAULT_TAIL = 200
_LOG_MAX_BYTES = 4 * 1024 * 1024


def _normalize_logs_tail(raw_tail) -> int:
    try:
        tail = int(str(raw_tail or "").strip())
    except (TypeError, ValueError):
        return _LOG_DEFAULT_TAIL
    return tail if tail in _LOG_TAIL_VALUES else _LOG_DEFAULT_TAIL


def _handle_logs(handler, parsed) -> bool:
    """Return a bounded tail window for an active-profile JarvisCopilot log file."""
    query = parse_qs(parsed.query)
    file_key = (query.get("file", ["agent"])[0] or "agent").strip().lower()
    filename = _LOG_FILE_WHITELIST.get(file_key)
    if not filename:
        return bad(handler, "Unknown log file", status=400)

    tail = _normalize_logs_tail(query.get("tail", [None])[0])
    try:
        from api.profiles import get_active_hermes_home

        hermes_home = Path(get_active_hermes_home()).expanduser()
    except Exception:
        hermes_home = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".jarviscopilot")).expanduser()

    log_dir = hermes_home / "logs"
    log_path = log_dir / filename
    try:
        # Defense in depth: the filename is hardcoded above, but keep the final
        # path anchored under the active profile's logs directory.
        if log_path.resolve(strict=False).parent != log_dir.resolve(strict=False):
            return bad(handler, "Invalid log file", status=400)
        if not log_path.exists() or not log_path.is_file():
            return j(handler, {
                "file": file_key,
                "tail": tail,
                "lines": [],
                "truncated": False,
                "total_bytes": 0,
                "mtime": None,
                "hint": f"Log file for {file_key} not found yet.",
            })
        st = log_path.stat()
        total_bytes = int(st.st_size)
        read_bytes = min(total_bytes, _LOG_MAX_BYTES)
        with log_path.open("rb") as fh:
            if total_bytes > read_bytes:
                fh.seek(total_bytes - read_bytes)
            raw = fh.read(read_bytes)
        text = raw.decode("utf-8", errors="replace")
        lines = text.splitlines()[-tail:]
        return j(handler, {
            "file": file_key,
            "tail": tail,
            "lines": lines,
            "truncated": total_bytes > read_bytes,
            "total_bytes": total_bytes,
            "mtime": st.st_mtime,
            "hint": "",
        })
    except Exception as exc:
        logger.exception("Failed to read whitelisted log file %s", file_key)
        return bad(handler, _sanitize_error(exc), status=500)


def _handle_self_improvement(handler, parsed) -> bool:
    """Return recent self-improvement / self-learning events for the UIs.

    Reads the active profile's ``self_improvement.log`` via the shared parser
    so the web + mobile clients can show what the agent has been learning:
    skills auto-created/patched, memory updated, and rejected attempts.
    """
    query = parse_qs(parsed.query)
    try:
        limit = int((query.get("limit", ["50"])[0]) or 50)
    except (ValueError, TypeError):
        limit = 50
    limit = max(1, min(limit, 500))
    try:
        from api.profiles import get_active_hermes_home

        hermes_home = Path(get_active_hermes_home()).expanduser()
    except Exception:
        hermes_home = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".jarviscopilot")).expanduser()
    try:
        from agent.self_improvement_log import read_recent

        entries = read_recent(limit=limit, home=hermes_home)
        return j(handler, {
            "entries": entries,
            "total": len(entries),
            "hint": "" if entries else "No self-improvement activity recorded yet.",
        })
    except Exception as exc:
        logger.exception("Failed to read self-improvement log")
        return bad(handler, _sanitize_error(exc), status=500)

# ── Insights endpoint ──────────────────────────────────────────────────────────

_LLM_WIKI_DOCS_URL = "https://jarviscopilot.nousresearch.com/docs/user-guide/skills/bundled/research/research-llm-wiki"
_LLM_WIKI_PAGE_DIRS = ("entities", "concepts", "comparisons", "queries")


def _llm_wiki_active_hermes_home() -> Path:
    try:
        from api.profiles import get_active_hermes_home
        return Path(get_active_hermes_home()).expanduser()
    except Exception:
        return Path(os.getenv("HERMES_HOME", str(Path.home() / ".jarviscopilot"))).expanduser()


def _llm_wiki_env_file_path(hermes_home: Path) -> str | None:
    env_path = hermes_home / ".env"
    if not env_path.exists() or not env_path.is_file():
        return None
    try:
        for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            if key.strip() != "WIKI_PATH":
                continue
            value = value.strip().strip('"').strip("'")
            return value or None
    except Exception:
        return None
    return None


def _llm_wiki_get_config_path_value(config: dict, dotted_key: str) -> str | None:
    if not isinstance(config, dict):
        return None
    if dotted_key in config and config.get(dotted_key):
        return str(config.get(dotted_key))
    cur = config
    for part in dotted_key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return str(cur) if cur else None


def _llm_wiki_config_path() -> str | None:
    try:
        from api.config import get_config as _get_cfg
        cfg = _get_cfg()
    except Exception:
        return None
    return (
        _llm_wiki_get_config_path_value(cfg, "skills.config.wiki.path")
        or _llm_wiki_get_config_path_value(cfg, "wiki.path")
    )


# Cap WIKI walks to prevent self-DoS if WIKI_PATH points at /, /etc, /home, etc.
# Real LLM wikis have under a few thousand files; 10k is generous and catches misconfig.
_LLM_WIKI_MAX_FILES = 10000
# Refuse to walk these system roots even if explicitly configured.
_LLM_WIKI_FORBIDDEN_ROOTS = frozenset(
    str(Path(p).expanduser().resolve()) for p in ("/", "/etc", "/usr", "/var", "/opt", "/sys", "/proc")
)


def _llm_wiki_resolve_path() -> tuple[Path, str, bool]:
    hermes_home = _llm_wiki_active_hermes_home()
    raw = os.getenv("WIKI_PATH") or _llm_wiki_env_file_path(hermes_home)
    source = "WIKI_PATH" if raw else "default"
    configured = bool(raw)
    if not raw:
        raw = _llm_wiki_config_path()
        if raw:
            source = "skills.config.wiki.path"
            configured = True
    if not raw:
        raw = "~/wiki"
    return Path(os.path.expandvars(raw)).expanduser(), source, configured


def _llm_wiki_safe_iso(ts: float | None) -> str | None:
    if not ts:
        return None
    try:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return None


def _llm_wiki_count_files(root: Path) -> int:
    if not root.exists() or not root.is_dir():
        return 0
    # Defense in depth: refuse to walk forbidden system roots even if WIKI_PATH
    # was set to one. The endpoint is auth-gated but a misconfigured server
    # shouldn't self-DoS by rglob'ing all of /etc on every Insights load.
    try:
        if str(root.resolve()) in _LLM_WIKI_FORBIDDEN_ROOTS:
            return 0
    except Exception:
        return 0
    count = 0
    iterated = 0
    for item in root.rglob("*"):
        iterated += 1
        if iterated > _LLM_WIKI_MAX_FILES:
            break  # bounded — prevents hangs on symlink loops or huge trees
        try:
            if item.is_file() and not any(part.startswith(".") for part in item.relative_to(root).parts):
                count += 1
        except Exception:
            continue
    return count


def _llm_wiki_page_files(wiki_path: Path) -> list[Path]:
    pages: list[Path] = []
    # Defense in depth: refuse forbidden system roots.
    try:
        if str(wiki_path.resolve()) in _LLM_WIKI_FORBIDDEN_ROOTS:
            return pages
    except Exception:
        return pages
    iterated = 0
    for dirname in _LLM_WIKI_PAGE_DIRS:
        section = wiki_path / dirname
        if not section.exists() or not section.is_dir():
            continue
        for item in section.rglob("*.md"):
            iterated += 1
            if iterated > _LLM_WIKI_MAX_FILES:
                return pages  # bounded
            try:
                rel = item.relative_to(section)
                if item.is_file() and not any(part.startswith(".") for part in rel.parts):
                    pages.append(item)
            except Exception:
                continue
    return pages


def _build_llm_wiki_status() -> dict:
    """Return private-safe LLM Wiki status metadata without reading page bodies."""
    try:
        wiki_path, path_source, path_configured = _llm_wiki_resolve_path()
        base = {
            "available": False,
            "enabled": False,
            "status": "missing",
            "entry_count": 0,
            "page_count": 0,
            "raw_source_count": 0,
            "last_updated": None,
            "last_writer": None,
            "path_configured": path_configured,
            "path_source": path_source,
            "toggle_available": False,
            "toggle_reason": "JarvisCopilot exposes WIKI_PATH/wiki.path for location, but no stable on/off config flag is currently available.",
            "docs_url": _LLM_WIKI_DOCS_URL,
        }
        if not wiki_path.exists():
            return base
        if not wiki_path.is_dir():
            base["status"] = "not_directory"
            return base

        page_files = _llm_wiki_page_files(wiki_path)
        status_files = [p for p in (wiki_path / "SCHEMA.md", wiki_path / "index.md", wiki_path / "log.md") if p.exists() and p.is_file()]
        status_files.extend(page_files)
        latest = None
        for item in status_files:
            try:
                mtime = item.stat().st_mtime
            except Exception:
                continue
            latest = mtime if latest is None else max(latest, mtime)

        base.update({
            "available": True,
            "enabled": True,
            "status": "ready" if page_files else "empty",
            "entry_count": len(page_files),
            "page_count": len(page_files),
            "raw_source_count": _llm_wiki_count_files(wiki_path / "raw"),
            "last_updated": _llm_wiki_safe_iso(latest),
        })
        return base
    except Exception as exc:
        return {
            "available": False,
            "enabled": False,
            "status": "error",
            "entry_count": 0,
            "page_count": 0,
            "raw_source_count": 0,
            "last_updated": None,
            "last_writer": None,
            "path_configured": False,
            "path_source": "unknown",
            "toggle_available": False,
            "toggle_reason": "Unable to inspect LLM Wiki status safely.",
            "docs_url": _LLM_WIKI_DOCS_URL,
            "error": type(exc).__name__,
        }


def _handle_llm_wiki_status(handler, parsed) -> bool:
    j(handler, _build_llm_wiki_status())
    return True


def _handle_insights_messages(handler, parsed) -> bool:
    """Per-message token usage + input composition for one session — powers the
    insights 'Messages' section. Reads the message_usage table the agent writes."""
    query = parse_qs(parsed.query or "")
    session_id = (query.get("session_id", [""])[0] or "").strip()
    try:
        limit = min(max(int(query.get("limit", ["200"])[0]), 1), 1000)
    except (ValueError, TypeError):
        limit = 200
    if not session_id:
        return j(handler, {"session_id": "", "messages": []})
    db = None
    try:
        from api.state_sync import _get_state_db
        db = _get_state_db()
        records = db.get_message_usage(session_id, limit=limit) if db else []
    except Exception as e:
        return j(handler, {"session_id": session_id, "messages": [], "error": str(e)})
    finally:
        try:
            if db:
                db.close()
        except Exception:
            pass
    return j(handler, {"session_id": session_id, "messages": records})


def _handle_insights(handler, parsed) -> bool:
    """Return usage analytics from local WebUI session data."""
    import collections
    import time as _time

    query = parse_qs(parsed.query)
    try:
        days = min(max(int(query.get("days", ["30"])[0]), 1), 365)
    except (ValueError, TypeError):
        days = 30

    now = _time.time()
    today = _time.localtime(now)
    today_midnight = _time.mktime((today.tm_year, today.tm_mon, today.tm_mday, 0, 0, 0, today.tm_wday, today.tm_yday, today.tm_isdst))
    day_secs = 86400
    first_day_ts = today_midnight - ((days - 1) * day_secs)
    cutoff = first_day_ts

    def _safe_usage_int(value) -> int:
        try:
            return max(int(float(value or 0)), 0)
        except (TypeError, ValueError):
            return 0

    def _safe_cost_float(value) -> float:
        if value is None:
            return 0.0
        try:
            if isinstance(value, str):
                value = value.strip().replace("$", "").replace(",", "")
                if not value:
                    return 0.0
            return max(float(value), 0.0)
        except (TypeError, ValueError):
            return 0.0

    def _session_usage_ts(session: dict) -> float:
        return session.get("updated_at", session.get("created_at", 0)) or session.get("created_at", 0) or 0

    # Walk session index (fast, no full JSON parse)
    sessions_data = []
    idx_path = SESSION_DIR / "_index.json"
    if idx_path.exists():
        try:
            idx = json.loads(idx_path.read_text(encoding="utf-8"))
        except Exception:
            idx = []
    else:
        idx = []

    for entry in idx:
        created = entry.get("created_at", 0) or 0
        updated = entry.get("updated_at", 0) or 0
        # Session is relevant if it was created or updated within the calendar window.
        if max(created, updated) < cutoff:
            continue
        sessions_data.append(entry)

    # Aggregate
    total_sessions = len(sessions_data)
    total_messages = 0
    total_input_tokens = 0
    total_output_tokens = 0
    total_cost = 0.0
    model_stats: dict[str, dict] = {}
    daily_tokens: dict[str, dict] = {}
    # Activity by day of week (0=Mon .. 6=Sun)
    dow_activity = collections.Counter()
    # Activity by hour of day (0-23)
    hod_activity = collections.Counter()

    for s in sessions_data:
        input_tokens = _safe_usage_int(s.get("input_tokens"))
        output_tokens = _safe_usage_int(s.get("output_tokens"))
        cost_value = _safe_cost_float(s.get("estimated_cost"))
        total_messages += _safe_usage_int(s.get("message_count"))
        total_input_tokens += input_tokens
        total_output_tokens += output_tokens
        total_cost += cost_value

        model = s.get("model") or "unknown"
        bucket = model_stats.setdefault(model, {
            "sessions": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost": 0.0,
        })
        bucket["sessions"] += 1
        bucket["input_tokens"] += input_tokens
        bucket["output_tokens"] += output_tokens
        bucket["cost"] += cost_value

        # Activity patterns
        ts = _session_usage_ts(s)
        if ts:
            try:
                dt = _time.localtime(ts)
                day_key = _time.strftime("%Y-%m-%d", dt)
                daily_bucket = daily_tokens.setdefault(day_key, {
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "sessions": 0,
                    "cost": 0.0,
                })
                daily_bucket["input_tokens"] += input_tokens
                daily_bucket["output_tokens"] += output_tokens
                daily_bucket["sessions"] += 1
                daily_bucket["cost"] += cost_value
                dow_activity[dt.tm_wday] += 1
                hod_activity[dt.tm_hour] += 1
            except Exception:
                pass

    # Build model breakdown
    total_tokens = total_input_tokens + total_output_tokens
    models_breakdown = []
    for model, stats in model_stats.items():
        row_total_tokens = stats["input_tokens"] + stats["output_tokens"]
        row_cost = round(stats["cost"], 6)
        models_breakdown.append({
            "model": model,
            "sessions": stats["sessions"],
            "input_tokens": stats["input_tokens"],
            "output_tokens": stats["output_tokens"],
            "total_tokens": row_total_tokens,
            "cost": row_cost,
            "session_share": int(round((stats["sessions"] / total_sessions) * 100)) if total_sessions else 0,
            "token_share": int(round((row_total_tokens / total_tokens) * 100)) if total_tokens else 0,
            "cost_share": int(round((row_cost / total_cost) * 100)) if total_cost else 0,
        })
    models_breakdown.sort(key=lambda r: (-r["cost"], -r["sessions"], r["model"]))

    daily_series = []
    for i in range(days):
        day_ts = first_day_ts + (i * day_secs)
        day_key = _time.strftime("%Y-%m-%d", _time.localtime(day_ts))
        bucket = daily_tokens.get(day_key, {
            "input_tokens": 0,
            "output_tokens": 0,
            "sessions": 0,
            "cost": 0.0,
        })
        daily_series.append({
            "date": day_key,
            "input_tokens": bucket["input_tokens"],
            "output_tokens": bucket["output_tokens"],
            "sessions": bucket["sessions"],
            "cost": round(bucket["cost"], 6),
        })

    # Day-of-week labels
    dow_labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    dow_data = [{"day": dow_labels[i], "sessions": dow_activity.get(i, 0)} for i in range(7)]

    # Hour-of-day data
    hod_data = [{"hour": h, "sessions": hod_activity.get(h, 0)} for h in range(24)]

    return j(handler, {
        "period_days": days,
        "total_sessions": total_sessions,
        "total_messages": total_messages,
        "total_input_tokens": total_input_tokens,
        "total_output_tokens": total_output_tokens,
        "total_tokens": total_tokens,
        "total_cost": round(total_cost, 6),
        "models": models_breakdown,
        "daily_tokens": daily_series,
        "activity_by_day": dow_data,
        "activity_by_hour": hod_data,
    })


# ── GET routes ────────────────────────────────────────────────────────────────


def _accept_loop_health(handler) -> dict:
    server = getattr(handler, "server", None)
    return {
        "requests_total": int(getattr(server, "accept_loop_requests_total", 0) or 0),
        "last_request_at": round(float(getattr(server, "accept_loop_last_request_at", 0.0) or 0.0), 3),
    }


def _streams_lock_health(timeout_seconds: float = 0.5) -> dict:
    t0 = time.time()
    acquired = STREAMS_LOCK.acquire(timeout=timeout_seconds)
    elapsed_ms = round((time.time() - t0) * 1000, 1)
    if not acquired:
        return {
            "status": "blocked",
            "timeout_seconds": timeout_seconds,
            "ms": elapsed_ms,
        }
    try:
        return {
            "status": "ok",
            "active_streams": len(STREAMS),
            "ms": elapsed_ms,
        }
    finally:
        STREAMS_LOCK.release()


def _run_lifecycle_health() -> dict:
    """Return active worker-run state independent of SSE stream presence."""
    # Import the module rather than relying only on imported scalar aliases so
    # LAST_RUN_FINISHED_AT stays fresh after unregister_active_run() updates it.
    from api import config as _live_config

    now = time.time()
    with _live_config.ACTIVE_RUNS_LOCK:
        runs = []
        for stream_id, raw in (_live_config.ACTIVE_RUNS or {}).items():
            item = dict(raw or {})
            started_at = item.get("started_at")
            try:
                age = max(0.0, now - float(started_at))
            except Exception:
                age = 0.0
            item.setdefault("stream_id", stream_id)
            item["age_seconds"] = round(age, 1)
            runs.append(item)
        last_finished = _live_config.LAST_RUN_FINISHED_AT
    runs.sort(key=lambda item: float(item.get("started_at") or 0.0))
    payload = {
        "active_runs": len(runs),
        "runs": runs,
        "last_run_finished_at": last_finished,
    }
    if runs:
        payload["oldest_run_age_seconds"] = runs[0].get("age_seconds", 0.0)
    elif last_finished:
        payload["idle_seconds_since_last_run"] = round(max(0.0, now - float(last_finished)), 1)
    return payload


def _deep_health_checks(stream_check: dict | None = None) -> tuple[dict, bool]:
    """Run cheap probes that exercise the state paths used by the UI shell.

    Plain /health intentionally stays tiny. /health?deep=1 is for supervisors
    and watchdogs that need to know whether the process can still touch the
    shared stream map, sidebar/session path, project state, and JarvisCopilot state.db
    without hitting the RST-before-write failure mode from #1458.

    `stream_check` is the result from a prior `_streams_lock_health()` call;
    if provided, it's reused so we don't acquire `STREAMS_LOCK` twice on the
    same /health?deep=1 request (per Opus advisor on stage-297).
    """
    checks: dict[str, dict] = {}

    checks["streams_lock"] = stream_check if stream_check is not None else _streams_lock_health()
    if checks["streams_lock"].get("status") != "ok":
        return checks, False

    t0 = time.time()
    try:
        sessions = all_sessions()
        checks["sessions"] = {
            "status": "ok",
            "count": len(sessions),
            "ms": round((time.time() - t0) * 1000, 1),
        }
    except Exception as exc:
        checks["sessions"] = {
            "status": "error",
            "error": type(exc).__name__,
            "ms": round((time.time() - t0) * 1000, 1),
        }

    t0 = time.time()
    try:
        projects = load_projects(_migrate=False)
        checks["projects"] = {
            "status": "ok",
            "count": len(projects),
            "ms": round((time.time() - t0) * 1000, 1),
        }
    except Exception as exc:
        checks["projects"] = {
            "status": "error",
            "error": type(exc).__name__,
            "ms": round((time.time() - t0) * 1000, 1),
        }

    t0 = time.time()
    try:
        db_path = _active_state_db_path()
        if not db_path.exists():
            checks["state_db"] = {
                "status": "missing",
                "ms": round((time.time() - t0) * 1000, 1),
            }
        else:
            with closing(sqlite3.connect(str(db_path))) as conn:
                conn.execute("PRAGMA schema_version").fetchone()
            checks["state_db"] = {
                "status": "ok",
                "ms": round((time.time() - t0) * 1000, 1),
            }
    except Exception as exc:
        checks["state_db"] = {
            "status": "error",
            "error": type(exc).__name__,
            "ms": round((time.time() - t0) * 1000, 1),
        }

    healthy = all(
        check.get("status") in {"ok", "missing"}
        for check in checks.values()
    )
    return checks, healthy


def _handle_health(handler, parsed):
    deep = parse_qs(parsed.query or "").get("deep", [""])[0].lower() in {"1", "true", "yes", "on"}
    stream_check = _streams_lock_health()
    run_check = _run_lifecycle_health()
    payload = {
        "status": "ok" if stream_check.get("status") == "ok" else "degraded",
        "sessions": len(SESSIONS),
        "active_streams": int(stream_check.get("active_streams") or 0),
        "active_runs": int(run_check.get("active_runs") or 0),
        "runs": run_check.get("runs", []),
        "last_run_finished_at": run_check.get("last_run_finished_at"),
        "uptime_seconds": round(time.time() - SERVER_START_TIME, 1),
        "accept_loop": _accept_loop_health(handler),
    }
    if "oldest_run_age_seconds" in run_check:
        payload["oldest_run_age_seconds"] = run_check["oldest_run_age_seconds"]
    if "idle_seconds_since_last_run" in run_check:
        payload["idle_seconds_since_last_run"] = run_check["idle_seconds_since_last_run"]
    if deep:
        if stream_check.get("status") != "ok":
            payload["checks"] = {"streams_lock": stream_check}
            return j(handler, payload, status=503)
        checks, healthy = _deep_health_checks(stream_check=stream_check)
        payload["checks"] = checks
        if not healthy:
            payload["status"] = "degraded"
            return j(handler, payload, status=503)
    if payload["status"] != "ok":
        return j(handler, payload, status=503)
    return j(handler, payload)


# ── Plugin visibility endpoint (#539) ───────────────────────────────────────
_PLUGIN_VISIBILITY_HOOKS = (
    "pre_tool_call",
    "post_tool_call",
    "pre_llm_call",
    "post_llm_call",
)
_PLUGIN_VISIBILITY_HOOK_SET = set(_PLUGIN_VISIBILITY_HOOKS)


def _get_plugin_manager_for_visibility():
    """Return JarvisCopilot's plugin manager for read-only WebUI visibility."""
    from jarviscopilot_cli.plugins import get_plugin_manager

    return get_plugin_manager()


def _clean_plugin_visibility_text(value, *, limit=240) -> str:
    """Return bounded display text without path/callback-like internals."""
    if value is None:
        return ""
    text = str(value).replace("\x00", "").strip()
    # Display metadata should be plain labels/descriptions. Drop multiline text
    # and common path separators rather than risk leaking local plugin paths.
    text = " ".join(text.split())
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def _plugin_visibility_payload(manager=None) -> dict:
    """Build a sanitized plugin/hook visibility payload for Settings.

    The JarvisCopilot manager stores manifests and callback objects internally.
    This endpoint intentionally exposes only safe, user-facing metadata and the
    four lifecycle hook names called out by the Settings visibility MVP. It
    never includes plugin source paths, callback names, callback reprs, or raw
    load errors because those can contain private filesystem details.
    """
    manager = manager or _get_plugin_manager_for_visibility()
    manager.discover_and_load(force=False)

    plugins = []
    raw_plugins = getattr(manager, "_plugins", {}) or {}
    for key, loaded in sorted(raw_plugins.items(), key=lambda item: str(item[0])):
        manifest = getattr(loaded, "manifest", None)
        if manifest is None:
            continue
        plugin_key = _clean_plugin_visibility_text(
            getattr(manifest, "key", None) or key or getattr(manifest, "name", ""),
            limit=120,
        )
        name = _clean_plugin_visibility_text(getattr(manifest, "name", "") or plugin_key, limit=120)
        version = _clean_plugin_visibility_text(getattr(manifest, "version", ""), limit=80)
        description = _clean_plugin_visibility_text(getattr(manifest, "description", ""), limit=280)
        registered = []
        for hook in list(getattr(manifest, "provides_hooks", []) or []) + list(getattr(loaded, "hooks_registered", []) or []):
            hook_name = str(hook or "").strip()
            if hook_name in _PLUGIN_VISIBILITY_HOOK_SET and hook_name not in registered:
                registered.append(hook_name)
        registered.sort(key=_PLUGIN_VISIBILITY_HOOKS.index)
        plugins.append({
            "name": name,
            "key": plugin_key or name,
            "version": version,
            "description": description,
            "enabled": bool(getattr(loaded, "enabled", False)),
            "hooks": registered,
        })

    return {
        "plugins": plugins,
        "empty": not bool(plugins),
        "supported_hooks": list(_PLUGIN_VISIBILITY_HOOKS),
        "read_only": True,
    }


def _handle_plugins(handler, parsed) -> bool:
    try:
        return j(handler, _plugin_visibility_payload())
    except Exception as exc:
        logger.warning("Failed to build plugin visibility payload: %s", exc)
        return j(
            handler,
            {
                "plugins": [],
                "empty": True,
                "supported_hooks": list(_PLUGIN_VISIBILITY_HOOKS),
                "read_only": True,
                "unavailable": True,
            },
        )


_SHELL_ERROR_HTML = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>JarvisCopilot is restarting</title>
</head>
<body style=\"margin:0;padding:2rem;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#111827;color:#e5e7eb;\">
  <main style=\"max-width:40rem;margin:10vh auto;line-height:1.5;\">
    <h1 style=\"font-size:1.5rem;margin:0 0 0.75rem;\">JarvisCopilot is restarting…</h1>
    <p style=\"margin:0;color:#cbd5e1;\">The WebUI shell could not load cleanly. Refresh in a moment if this page does not update automatically.</p>
  </main>
</body>
</html>"""


def _serve_shell_unavailable(handler, exc: Exception) -> bool:
    """Return HTML for shell-route failures so `/` never renders JSON."""
    logger.warning("Failed to serve WebUI shell route: %s", exc)
    t(
        handler,
        _SHELL_ERROR_HTML,
        status=503,
        content_type="text/html; charset=utf-8",
    )
    return True


def _serve_manifest(handler) -> bool:
    """Serve static/manifest.json with the correct PWA Content-Type.

    Shared by the root (/manifest.json, /manifest.webmanifest) and
    session-prefixed (/session/manifest.json, /session/manifest.webmanifest)
    routes so Firefox Android can fetch the manifest when installing from
    a /session/<id> page.  See #2226.
    """
    static_root = Path(__file__).parent.parent / "static"
    manifest_path = (static_root / "manifest.json").resolve()
    if manifest_path.exists():
        data = manifest_path.read_bytes()
        handler.send_response(200)
        handler.send_header("Content-Type", "application/manifest+json; charset=utf-8")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)
        return True
    return j(handler, {"error": "not found"}, status=404)


@answers_http_errors
def handle_get(handler, parsed) -> bool:
    """Handle all GET routes. Returns True if handled, False for 404."""
    if dispatch_mount(Request(handler, parsed, "GET")):
        return True

    if parsed.path.startswith("/session/static/"):
        # Strip the leading "/session" so _serve_static() sees a path that
        # starts with "/static/" (its required prefix). _serve_static enforces
        # its own path-traversal sandbox via Path.resolve()+relative_to().
        stripped = parsed._replace(path=parsed.path[len("/session"):])
        return _serve_static(handler, stripped)

    # Firefox Android resolves <link rel="manifest"> against the page URL
    # before the dynamic <base href> script runs when installing from
    # /session/<id>, producing requests like /session/manifest.json.
    # Without this guard the catch-all below returns index.html instead of
    # the manifest, and Firefox falls back to a generated letter icon.
    # See #2226.
    if parsed.path in ("/session/manifest.json", "/session/manifest.webmanifest"):
        return _serve_manifest(handler)

    if parsed.path in ("/", "/index.html") or parsed.path.startswith("/session/"):
        try:
            from urllib.parse import quote
            from api.updates import WEBUI_VERSION
            version_token = quote(WEBUI_VERSION, safe="")
            from api.extensions import inject_extension_tags

            html = (
                _INDEX_HTML_PATH.read_text(encoding="utf-8")
                .replace("__WEBUI_VERSION__", version_token)
                .replace("__MAX_UPLOAD_BYTES__", str(MAX_UPLOAD_BYTES))
            )
            return t(
                handler,
                inject_extension_tags(html),
                content_type="text/html; charset=utf-8",
            )
        except Exception as exc:
            return _serve_shell_unavailable(handler, exc)

    if parsed.path == "/login":
        _settings = load_settings()
        _bn = _html.escape(_settings.get("bot_name") or "JarvisCopilot")
        _lang = _settings.get("language", "en")
        _login_strings = _LOGIN_LOCALE[
            _resolve_login_locale_key(_lang)
        ]
        from urllib.parse import quote
        from api.updates import WEBUI_VERSION
        version_token = quote(WEBUI_VERSION, safe="")
        _page = (
            _LOGIN_PAGE_HTML.replace("{{BOT_NAME}}", _bn)
            .replace("{{BOT_NAME_INITIAL}}", _bn[0].upper())
            .replace("{{WEBUI_VERSION}}", version_token)
            .replace("{{LANG}}", _html.escape(_login_strings["lang"]))
            .replace("{{LOGIN_TITLE}}", _html.escape(_login_strings["title"]))
            .replace("{{LOGIN_SUBTITLE}}", _html.escape(_login_strings["subtitle"]))
            .replace(
                "{{LOGIN_PLACEHOLDER}}", _html.escape(_login_strings["placeholder"])
            )
            .replace("{{LOGIN_BTN}}", _html.escape(_login_strings["btn"]))
            .replace("{{LOGIN_INVALID_PW}}", _html.escape(_login_strings["invalid_pw"]))
            .replace(
                "{{LOGIN_CONN_FAILED}}", _html.escape(_login_strings["conn_failed"])
            )
        )
        return t(handler, _page, content_type="text/html; charset=utf-8")

    if parsed.path == "/api/auth/status":
        from api.auth import is_auth_enabled, parse_cookie, verify_session
        from api.pairing import is_pairing_required

        logged_in = False
        if is_auth_enabled():
            cv = parse_cookie(handler)
            logged_in = bool(cv and verify_session(cv))
        return j(handler, {
            "auth_enabled": is_auth_enabled(),
            "logged_in": logged_in,
            "pairing_required": is_pairing_required(),
        })

    if parsed.path == "/pair":
        return t(handler, _PAIR_PAGE_HTML, content_type="text/html; charset=utf-8")

    if parsed.path.startswith("/api/forms/"):
        # A form the agent drew in the conversation.
        from api.forms import handle_get as _forms_get

        if _forms_get(handler, parsed):
            return True

    if parsed.path == "/api/health/devices" or "/health" in parsed.path:
        # Wearable health: scores, days and settings. Checked before the
        # Integrations routes, which would read "health" as a space's tail.
        from api.health_routes import handle_get as _health_get

        if _health_get(handler, parsed):
            return True

    if parsed.path.startswith("/api/imessage-memory"):
        # iMessage memory: his card on the Integrations page, and the Mac's config.
        from api.imessage_memory_routes import handle_get as _imessage_memory_get

        if _imessage_memory_get(handler, parsed):
            return True

    if (parsed.path in ("/api/integrations", "/api/integration-cards")
            or parsed.path.startswith("/api/integrations/")):
        # The Integrations page (web + phone): what exists, what it holds, what it runs,
        # and each integration's own card (/api/integration-cards).
        from api.integrations_routes import handle_get as _integrations_get, is_ui_path
        from api.profiles import cron_profile_context

        # An integration's UI runs its scripts (up to tens of seconds) and never
        # touches cron.jobs: outside the process-wide cron lock, or every other
        # integrations/crons request on every device waits behind it.
        if is_ui_path(parsed.path):
            if _integrations_get(handler, parsed):
                return True
        else:
            # Wrapped like every other cron entry point: these read and write
            # jobs.json through cron.jobs, which resolves the profile at call time.
            with cron_profile_context():
                if _integrations_get(handler, parsed):
                    return True

    if parsed.path == "/api/auth/pair/status":
        # Polled by the CLI; STATE_DIR is local so this could also be read
        # from disk, but the HTTP endpoint is convenient for `curl` and for
        # remote-trusted callers that have a valid session.
        from api.pairing import poll_pairing_code
        from urllib.parse import parse_qs as _pq
        qs = _pq(parsed.query or "")
        code = (qs.get("code", [""])[0] or "").strip().upper()
        if not code:
            return j(handler, {"error": "code required"}, status=400)
        return j(handler, poll_pairing_code(code))

    if parsed.path in ("/manifest.json", "/manifest.webmanifest"):
        return _serve_manifest(handler)

    if parsed.path == "/sw.js":
        static_root = Path(__file__).parent.parent / "static"
        sw_path = (static_root / "sw.js").resolve()
        if sw_path.exists():
            # Inject the current git-derived version as the cache name so the
            # service worker cache busts automatically on every new deploy.
            from urllib.parse import quote
            from api.updates import WEBUI_VERSION
            version_token = quote(WEBUI_VERSION, safe="")
            text = sw_path.read_text(encoding="utf-8").replace(
                "__WEBUI_VERSION__", version_token
            )
            data = text.encode("utf-8")
            handler.send_response(200)
            handler.send_header("Content-Type", "application/javascript; charset=utf-8")
            handler.send_header("Cache-Control", "no-store")
            handler.send_header("Service-Worker-Allowed", "/")
            handler.send_header("Content-Length", str(len(data)))
            handler.end_headers()
            handler.wfile.write(data)
            return True
        return j(handler, {"error": "not found"}, status=404)

    if parsed.path == "/favicon.ico":
        static_root = Path(__file__).parent.parent / "static"
        ico_path = (static_root / "favicon.ico").resolve()
        if ico_path.exists() and ico_path.is_file():
            data = ico_path.read_bytes()
            handler.send_response(200)
            handler.send_header("Content-Type", "image/x-icon")
            handler.send_header("Content-Length", str(len(data)))
            handler.send_header("Cache-Control", "public, max-age=86400")
            handler.end_headers()
            handler.wfile.write(data)
        else:
            handler.send_response(204)
            handler.end_headers()
        return True

    # ── Insights / knowledge status ──
    if parsed.path == "/api/insights":
        return _handle_insights(handler, parsed)

    if parsed.path == "/api/insights/messages":
        return _handle_insights_messages(handler, parsed)

    if parsed.path == "/api/web/config":
        from api.web_config import handle_web_config_get
        if handle_web_config_get(handler, parsed):
            return True
    if parsed.path == "/api/tool-keys":
        from api.tool_keys import handle_tool_keys_get
        if handle_tool_keys_get(handler, parsed):
            return True
    if parsed.path in ("/api/costs", "/api/costs/service"):
        from api.costs_routes import handle_costs_get
        if handle_costs_get(handler, parsed):
            return True
    if parsed.path == "/api/wiki/status":
        return _handle_llm_wiki_status(handler, parsed)
    if parsed.path == "/api/logs":
        return _handle_logs(handler, parsed)
    if parsed.path == "/api/self-improvement/recent":
        return _handle_self_improvement(handler, parsed)
    if parsed.path == "/api/auth/handoff":
        from api.auth import handle_auth_handoff
        return handle_auth_handoff(handler, parsed)

    if parsed.path == "/health":
        return _handle_health(handler, parsed)

    if parsed.path == "/api/health/agent":
        return j(handler, build_agent_health_payload())

    if parsed.path == "/api/system/health":
        j(handler, build_system_health_payload())
        return True

    if parsed.path == "/api/models":
        from api.config import picker_catalog
        return j(handler, picker_catalog(get_available_models()))

    if parsed.path == "/api/tools/catalog":
        return j(handler, _build_tools_catalog())

    if parsed.path == "/api/models/live":
        return _handle_live_models(handler, parsed)

    # ── Providers (GET) ──
    if parsed.path == "/api/providers":
        return j(handler, get_providers())

    # ── Plugins/hooks visibility (read-only, no callback/source internals) ──
    if parsed.path == "/api/plugins":
        return _handle_plugins(handler, parsed)
    if parsed.path == "/api/provider/quota":
        query = parse_qs(parsed.query)
        provider_id = (query.get("provider", [""])[0] or None)
        refresh = (query.get("refresh", [""])[0] or "").strip().lower() in {"1", "true", "yes", "on"}
        return j(handler, get_provider_quota(provider_id, refresh=refresh))

    if parsed.path == "/api/provider/quota/all":
        query = parse_qs(parsed.query)
        refresh = (query.get("refresh", [""])[0] or "").strip().lower() in {"1", "true", "yes", "on"}
        return j(handler, get_all_provider_quota(refresh=refresh))

    if parsed.path == "/api/provider/cost-history":
        query = parse_qs(parsed.query)
        provider_id = (query.get("provider", [""])[0] or None)
        days_raw = (query.get("days", ["7"])[0] or "7").strip()
        try:
            days = max(1, min(int(days_raw), 365))
        except (ValueError, TypeError):
            days = 7
        return j(handler, get_provider_cost_history(provider_id, days))

    if parsed.path == "/api/settings":
        settings = load_settings()
        # Never expose the stored password hash to clients
        settings.pop("password_hash", None)
        # Surface env-var precedence so the UI can disable the password field
        # instead of silently no-oping the save (#1560). The setting takes
        # precedence in api.auth.get_password_hash(), but until now the UI
        # had no way to know — see issue #1139 / #1560.
        settings["password_env_var"] = bool(
            os.getenv("HERMES_WEBUI_PASSWORD", "").strip()
        )
        # Inject the running version so the UI badge stays in sync with git tags
        # without any manual release step.
        try:
            from api.updates import AGENT_VERSION, WEBUI_VERSION
            settings["webui_version"] = WEBUI_VERSION
            settings["agent_version"] = AGENT_VERSION
        except Exception:
            pass
        return j(handler, settings)

    if parsed.path == "/api/reasoning":
        # Current reasoning config (shared source of truth with the CLI —
        # reads display.show_reasoning and agent.reasoning_effort from
        # the active profile's config.yaml).
        return j(handler, get_reasoning_status())

    if parsed.path == "/api/onboarding/status":
        return j(handler, get_onboarding_status())

    if parsed.path.startswith("/extensions/"):
        from api.extensions import serve_extension_static

        return serve_extension_static(handler, parsed)

    if parsed.path.startswith("/static/"):
        return _serve_static(handler, parsed)


    if parsed.path == "/api/background/status":
        sid = query_sid(parsed, "Missing session_id")
        from api.background import get_results
        return j(handler, {"results": get_results(sid)})


    if parsed.path == "/api/projects":
        # ── Profile scoping (#1614) ────────────────────────────────────────
        # Default: filter to the active profile. ?all_profiles=1 returns the
        # aggregate list so settings/admin UIs can still see everything.
        from api.profiles import get_active_profile_name
        active_profile = get_active_profile_name()
        all_projects = load_projects()
        all_profiles = _all_profiles_query_flag(parsed)
        if all_profiles:
            scoped = all_projects
        else:
            scoped = [p for p in all_projects
                      if _profiles_match(p.get("profile"), active_profile)]
        return j(handler, {
            "projects": scoped,
            "all_profiles": all_profiles,
            "active_profile": active_profile,
            "other_profile_count": len(all_projects) - len(scoped),
        })


    if parsed.path == "/api/workspaces":
        return j(
            handler, {"workspaces": load_workspaces(), "last": get_last_workspace()}
        )

    if parsed.path == "/api/workspaces/suggest":
        qs = parse_qs(parsed.query)
        prefix = qs.get("prefix", [""])[0]
        return j(
            handler,
            {
                "suggestions": list_workspace_suggestions(prefix),
                "prefix": prefix,
            },
        )


    if parsed.path == "/api/list":
        return _handle_list_dir(handler, parsed)

    if parsed.path == "/api/personalities":
        # Read personalities from config.yaml agent.personalities section
        # (matches jarviscopilot CLI behavior, not filesystem SOUL.md approach)
        from api.config import reload_config as _reload_cfg

        _reload_cfg()  # pick up config.yaml changes without server restart
        from api.config import get_config as _get_cfg

        _cfg = _get_cfg()
        agent_cfg = _cfg.get("agent", {})
        raw_personalities = agent_cfg.get("personalities", {})
        personalities = []
        if isinstance(raw_personalities, dict):
            for name, value in raw_personalities.items():
                desc = ""
                if isinstance(value, dict):
                    desc = value.get("description", "")
                elif isinstance(value, str):
                    desc = value[:80] + ("..." if len(value) > 80 else "")
                personalities.append({"name": name, "description": desc})
        # The globally-active personality (applies to all sessions) so the
        # picker can pre-select it even on a session that has none set.
        active = (agent_cfg.get("personality") or "") if isinstance(agent_cfg, dict) else ""
        return j(handler, {"personalities": personalities, "active": active})

    if parsed.path == "/api/personality/active":
        # The globally-active personality's RESOLVED system prompt, so on-device
        # models can speak in the same JARVIS persona as the server agent.
        from api.config import reload_config as _rc_p, get_config as _gc_p

        _rc_p()
        _cfg_p = _gc_p()
        agent_cfg = _cfg_p.get("agent", {}) or {}
        name = (agent_cfg.get("personality") or "").strip()
        raw = agent_cfg.get("personalities", {})
        prompt = ""
        if name and isinstance(raw, dict) and name in raw:
            value = raw[name]
            if isinstance(value, dict):
                parts = [value.get("system_prompt", "") or value.get("prompt", "")]
                if value.get("tone"):
                    parts.append(f"Tone: {value['tone']}")
                if value.get("style"):
                    parts.append(f"Style: {value['style']}")
                prompt = "\n".join(p for p in parts if p)
            else:
                prompt = str(value)
        return j(handler, {"name": name, "prompt": prompt})

    if parsed.path == "/api/git-info":
        qs = parse_qs(parsed.query)
        sid = qs.get("session_id", [""])[0]
        if not sid:
            return bad(handler, "session_id required")
        s = session_or_404(sid)
        from api.workspace import git_info_for_workspace

        info = git_info_for_workspace(Path(s.workspace))
        return j(handler, {"git": info})

    if parsed.path == "/api/commands":
        from api.commands import list_commands
        return j(handler, {"commands": list_commands()})

    if parsed.path == "/api/updates/check":
        settings = load_settings()
        if not settings.get("check_for_updates", True):
            return j(handler, {"disabled": True})
        qs = parse_qs(parsed.query)
        force = qs.get("force", ["0"])[0] == "1"
        # ?simulate=1 returns fake behind counts for UI testing (localhost only)
        if (
            qs.get("simulate", ["0"])[0] == "1"
            and handler.client_address[0] == "127.0.0.1"
        ):
            return j(
                handler,
                {
                    "webui": {
                        "name": "webui",
                        "behind": 3,
                        "current_sha": "abc1234",
                        "latest_sha": "def5678",
                        "branch": "master",
                        "repo_url": "https://github.com/nesquena/jarviscopilot-webui",
                        "compare_url": "https://github.com/nesquena/jarviscopilot-webui/compare/abc1234...def5678",
                    },
                    "agent": {
                        "name": "agent",
                        "behind": 1,
                        "current_sha": "aaa0001",
                        "latest_sha": "bbb0002",
                        "branch": "master",
                        "repo_url": "https://github.com/NousResearch/jarviscopilot",
                        "compare_url": "https://github.com/NousResearch/jarviscopilot/compare/aaa0001...bbb0002",
                    },
                    "checked_at": 0,
                },
            )
        from api.updates import check_for_updates

        return j(handler, check_for_updates(force=force))

    if parsed.path == "/api/chat/stream/status":
        stream_id = parse_qs(parsed.query).get("stream_id", [""])[0]
        active = stream_id in STREAMS
        payload = {"active": active, "stream_id": stream_id, "replay_available": False}
        try:
            journal = find_run_summary(stream_id) if stream_id else None
        except Exception:
            journal = None
        if journal:
            payload["replay_available"] = True
            payload["journal"] = _run_journal_status_payload(journal, active=active)
        return j(handler, payload)

    if parsed.path == "/api/chat/cancel":
        stream_id = parse_qs(parsed.query).get("stream_id", [""])[0]
        if not stream_id:
            return bad(handler, "stream_id required")
        cancelled = cancel_stream(stream_id)
        return j(handler, {"ok": True, "cancelled": cancelled, "stream_id": stream_id})

    if parsed.path == "/api/chat/stream":
        return _handle_sse_stream(handler, parsed)

    if parsed.path == "/api/terminal/output":
        return _handle_terminal_output(handler, parsed)

    if parsed.path == '/api/sessions/gateway/stream':
        return _handle_gateway_sse_stream(handler, parsed)

    if parsed.path == '/api/session/events':
        return _handle_session_events_sse(handler, parsed)

    if parsed.path == "/api/media":
        return _handle_media(handler, parsed)

    if parsed.path == "/api/link-preview":
        from api.link_preview import fetch_preview
        url = parse_qs(parsed.query).get("url", [""])[0].strip()
        preview = fetch_preview(url) if url else None
        if preview is None:
            return j(handler, {"error": "no preview"}, status=404)
        return j(handler, preview)

    if parsed.path == "/api/file/raw":
        return _handle_file_raw(handler, parsed)

    if parsed.path == "/api/file":
        return _handle_file_read(handler, parsed)

    if parsed.path == "/api/onboarding/oauth/poll":
        qs = parse_qs(parsed.query)
        flow_id = qs.get("flow_id", [""])[0]
        try:
            return j(
                handler,
                poll_onboarding_oauth_flow(flow_id),
                extra_headers={"Cache-Control": "no-store"},
            )
        except ValueError as e:
            return bad(handler, str(e))
        except KeyError as e:
            return bad(handler, str(e), 404)

    # ── Cron API (GET) ──
    # All cron handlers touch cron.jobs which resolves HERMES_HOME from
    # os.environ (process-global) at call time. Wrap in cron_profile_context
    # so the TLS-active profile's jobs.json is read, not the process default.
    if parsed.path == "/api/crons":
        from cron.jobs import list_jobs
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return j(handler, {"jobs": _cron_jobs_for_api(list_jobs(include_disabled=True))})

    if parsed.path == "/api/crons/output":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_output(handler, parsed)

    if parsed.path == "/api/crons/history":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_history(handler, parsed)

    if parsed.path == "/api/crons/run":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_run_detail(handler, parsed)

    if parsed.path == "/api/crons/recent":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_recent(handler, parsed)

    if parsed.path == "/api/crons/status":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_status(handler, parsed)

    # ── Skills API (GET) ──
    if parsed.path == "/api/skills":
        qs = parse_qs(parsed.query)
        category = qs.get("category", [None])[0]
        data = _skills_list_from_dir(_active_skills_dir(), category=category)
        return j(handler, {"skills": data.get("skills", [])})

    if parsed.path == "/api/skills/content":
        qs = parse_qs(parsed.query)
        name = qs.get("name", [""])[0]
        if not name:
            return j(handler, {"error": "name required"}, status=400)
        file_path = qs.get("file", [""])[0]
        if file_path:
            # Serve a linked file from the skill directory
            import re as _re

            if _re.search(r"[*?\[\]]", name):
                return bad(handler, "Invalid skill name", 400)
            skills_dir = _active_skills_dir()
            skill_dir, _skill_md = _find_skill_in_dirs(
                name, _active_skill_search_dirs(skills_dir)
            )
            if not skill_dir:
                return bad(handler, "Skill not found", 404)
            target = (skill_dir / file_path).resolve()
            try:
                target.relative_to(skill_dir.resolve())
            except ValueError:
                return bad(handler, "Invalid file path", 400)
            if not target.exists() or not target.is_file():
                return bad(handler, "File not found", 404)
            return j(
                handler,
                {"content": target.read_text(encoding="utf-8"), "path": file_path},
            )
        data = _skill_view_from_active_dir(name)
        if not isinstance(data.get("linked_files"), dict):
            data["linked_files"] = {}
        return j(handler, data)

    # ── Memory API (GET) ──
    if parsed.path == "/api/memory":
        return _handle_memory_read(handler)

    # ── Code-Memory API (GET) ──
    if parsed.path == "/api/code-memory":
        return _handle_code_memory_read(handler, parsed)
    if parsed.path == "/api/code-memory/projects":
        return _handle_code_memory_projects(handler)
    if parsed.path == "/api/code-memory/stats":
        return _handle_code_memory_stats(handler)
    if parsed.path == "/api/code-memory/search":
        return _handle_code_memory_search(handler, parsed)
    if parsed.path == "/api/code-memory/entries":
        return _handle_code_memory_entries(handler, parsed)
    if parsed.path == "/api/code-memory/digest":
        return _handle_code_memory_digest(handler, parsed)

    if parsed.path == "/api/notify/targets":
        return _handle_notify_list(handler)

    # ── Photon (iMessage) provider setup (GET) ──
    if parsed.path == "/api/integrations/photon":
        from api.photon_config import get_photon_config

        return j(handler, get_photon_config())

    # ── Profile API (GET) ──
    if parsed.path == "/api/profiles":
        from api.profiles import list_profiles_api, get_active_profile_name

        return j(
            handler,
            {"profiles": list_profiles_api(), "active": get_active_profile_name()},
        )

    if parsed.path == "/api/profile/active":
        from api.profiles import get_active_profile_name, get_active_hermes_home

        return j(
            handler,
            {"name": get_active_profile_name(), "path": str(get_active_hermes_home())},
        )

    # ── Gateway Status (GET) ──
    if parsed.path == "/api/gateway/status":
        import datetime
        identity_map = _load_gateway_session_identity_map()
        sessions_path = _gateway_session_metadata_path()

        # Detect whether the gateway process is alive, independent of
        # connected messaging platforms.  An empty identity_map just
        # means zero platforms connected, not that the gateway is down.
        #
        # agent_health.build_agent_health_payload() is the authoritative
        # signal: it reads gateway.status runtime metadata and returns a
        # tri-state `alive` field (True/False/None).  This avoids the
        # false-negative where the gateway is running but has zero active
        # messaging sessions (empty identity_map).
        #
        # `alive` tri-state semantics:
        #   True  → gateway process is alive
        #   False → gateway metadata exists but process is down
        #   None  → no gateway metadata/status available; this WebUI
        #           setup is probably not configured with a gateway
        health = build_agent_health_payload()
        alive = health.get("alive")
        if alive is True:
            running = True
            configured = True
        elif alive is False:
            running = False
            configured = True
        else:  # alive is None → gateway not configured / unavailable
            running = bool(identity_map)
            configured = False

        platforms_set: set[str] = set()
        for meta in identity_map.values():
            raw = meta.get("raw_source") or meta.get("platform") or ""
            norm = _normalize_messaging_source(raw)
            if norm:
                platforms_set.add(norm)
        _PLATFORM_LABELS = {
            "telegram": "Telegram",
            "discord": "Discord",
            "slack": "Slack",
            "email": "Email",
            "web": "Web",
            "api": "API",
        }
        platforms = sorted(
            [{"name": p, "label": _PLATFORM_LABELS.get(p, p.title())} for p in platforms_set],
            key=lambda x: x["label"],
        )
        last_active = ""
        if running and sessions_path.exists():
            try:
                mtime = sessions_path.stat().st_mtime
                last_active = datetime.datetime.fromtimestamp(mtime).isoformat()
            except Exception:
                pass
        return j(handler, {
            "running": running,
            "configured": configured,
            "platforms": platforms,
            "last_active": last_active,
            "session_count": len(identity_map),
        })

    # ── MCP Servers (GET) ──
    if parsed.path == "/api/mcp/servers":
        return _handle_mcp_servers_list(handler)

    # ── MCP Tools (GET) ──
    if parsed.path == "/api/mcp/tools":
        return _handle_mcp_tools_list(handler)

    # ── Checkpoints / Rollback (GET) ──
    if parsed.path == "/api/rollback/list":
        qs = parse_qs(parsed.query)
        workspace = qs.get("workspace", [""])[0]
        if not workspace:
            return bad(handler, "workspace query parameter is required")
        try:
            from api.rollback import list_checkpoints
            return j(handler, list_checkpoints(workspace))
        except ValueError as e:
            return bad(handler, str(e))
        except Exception as e:
            logger.exception("rollback/list failed")
            return bad(handler, str(e), status=500)

    if parsed.path == "/api/rollback/diff":
        qs = parse_qs(parsed.query)
        workspace = qs.get("workspace", [""])[0]
        checkpoint = qs.get("checkpoint", [""])[0]
        if not workspace or not checkpoint:
            return bad(handler, "workspace and checkpoint query parameters are required")
        try:
            from api.rollback import get_checkpoint_diff
            return j(handler, get_checkpoint_diff(workspace, checkpoint))
        except ValueError as e:
            return bad(handler, str(e))
        except Exception as e:
            logger.exception("rollback/diff failed")
            return bad(handler, str(e), status=500)

    return False  # 404


# ── GET route helpers


@answers_http_errors
def handle_post(handler, parsed) -> bool:
    """Handle all POST routes. Returns True if handled, False for 404."""
    diag = RequestDiagnostics.maybe_start("POST", parsed.path, logger=logger)
    if parsed.path == "/api/csp-report":
        if diag:
            diag.stage("csp_report")
        try:
            return _handle_csp_report(handler)
        finally:
            if diag:
                diag.finish()
    # CSRF: reject cross-origin browser requests
    if diag:
        diag.stage("csrf")
    if not check_csrf(handler):
        try:
            return j(handler, {"error": "Cross-origin request rejected"}, status=403)
        finally:
            if diag:
                diag.finish()

    if parsed.path == "/api/upload":
        return handle_upload(handler)
    if parsed.path == "/api/upload/extract":
        return handle_upload_extract(handler)
    if parsed.path == "/api/transcribe":
        return handle_transcribe(handler)

    req = Request(handler, parsed, "POST")
    if dispatch_mount(req):
        return True

    if diag:
        diag.stage("read_body")
    try:
        body = req.body
    except Exception:
        if diag:
            diag.finish()
        raise

    if parsed.path == "/api/flow/cleanup":
        from api.agent_notes_routes import handle_flow_cleanup
        status, payload = handle_flow_cleanup(body)
        return j(handler, payload, status=status)


    if parsed.path == "/api/web/config":
        from api.web_config import handle_web_config_post
        if handle_web_config_post(handler, parsed, body):
            return True
    if parsed.path == "/api/tool-keys":
        from api.tool_keys import handle_tool_keys_post
        if handle_tool_keys_post(handler, parsed, body):
            return True
    if parsed.path.startswith("/api/costs/"):
        from api.costs_routes import handle_costs_post
        if handle_costs_post(handler, parsed, body):
            return True


    if parsed.path == "/api/default-model":
        try:
            return j(handler, set_hermes_default_model(body.get("model")))
        except ValueError as e:
            return bad(handler, str(e))
        except RuntimeError as e:
            return bad(handler, str(e), 500)

    # ── Providers (POST) ──
    if parsed.path == "/api/providers":
        provider_id = (body.get("provider") or "").strip().lower()
        api_key = body.get("api_key")
        if not provider_id:
            return bad(handler, "provider is required")
        if api_key is not None:
            api_key = str(api_key).strip() or None
        result = set_provider_key(provider_id, api_key)
        if not result.get("ok"):
            return bad(handler, result.get("error", "Unknown error"))
        return j(handler, result)

    if parsed.path == "/api/providers/delete":
        provider_id = (body.get("provider") or "").strip().lower()
        if not provider_id:
            return bad(handler, "provider is required")
        result = remove_provider_key(provider_id)
        if not result.get("ok"):
            return bad(handler, result.get("error", "Unknown error"))
        return j(handler, result)

    if parsed.path == "/api/reasoning":
        # CLI-parity /reasoning handler — writes to the same config.yaml keys
        # the CLI uses (display.show_reasoning, agent.reasoning_effort) so a
        # preference set via WebUI is honoured in the terminal REPL and vice
        # versa.  Body is one of:
        #   {"display": "show"|"hide"|"on"|"off"}   → display.show_reasoning
        #   {"effort":  "none"|"minimal"|"low"|"medium"|"high"|"xhigh"}
        #                                            → agent.reasoning_effort
        try:
            display = body.get("display")
            effort = body.get("effort")
            if display is not None:
                flag = str(display).strip().lower()
                if flag in ("show", "on", "true", "1"):
                    return j(handler, set_reasoning_display(True))
                if flag in ("hide", "off", "false", "0"):
                    return j(handler, set_reasoning_display(False))
                return bad(handler, f"display must be show|hide|on|off (got '{display}')")
            if effort is not None:
                return j(handler, set_reasoning_effort(effort))
            return bad(handler, "reasoning: must supply 'display' or 'effort'")
        except ValueError as e:
            return bad(handler, str(e))
        except RuntimeError as e:
            return bad(handler, str(e), 500)

    if parsed.path == "/api/admin/reload":
        # Hot-reload api.models module to pick up code changes without restart.
        import importlib
        from api import models as _models
        importlib.reload(_models)
        # Also re-expose get_session from the reloaded module so routes.py
        # continues to work (routes.py imported it at module level).
        import api.routes as _routes
        _routes.get_session = _models.get_session
        _routes.Session = _models.Session
        _routes.compact = _models.compact
        return j(handler, {"status": "ok", "reloaded": "api.models"})


    if parsed.path == "/api/personality/set":
        need(body, "session_id")
        if "name" not in body:
            return bad(handler, "Missing required field: name")
        sid = body["session_id"]
        name = body["name"].strip()
        s = session_or_404(sid, full=True)
        # Resolve personality from config.yaml agent.personalities section
        # (matches jarviscopilot CLI behavior)
        prompt = ""
        if name:
            from api.config import reload_config as _reload_cfg2

            _reload_cfg2()  # pick up config changes without restart
            from api.config import get_config as _get_cfg2

            _cfg2 = _get_cfg2()
            agent_cfg = _cfg2.get("agent", {})
            raw_personalities = agent_cfg.get("personalities", {})
            if not isinstance(raw_personalities, dict) or name not in raw_personalities:
                return bad(
                    handler, f'Personality "{name}" not found in config.yaml', 404
                )
            value = raw_personalities[name]
            # Resolve prompt using the same logic as jarviscopilot cli.py
            if isinstance(value, dict):
                parts = [value.get("system_prompt", "") or value.get("prompt", "")]
                if value.get("tone"):
                    parts.append(f"Tone: {value['tone']}")
                if value.get("style"):
                    parts.append(f"Style: {value['style']}")
                prompt = "\n".join(p for p in parts if p)
            else:
                prompt = str(value)
        with _get_session_agent_lock(sid):
            s.personality = name if name else None
            s.save()
        # Persist globally so the personality applies to ALL sessions (current +
        # future), not just this one — matches the settings copy ("every response").
        _set_global_personality(name if name else "")
        return j(handler, {"ok": True, "personality": s.personality, "prompt": prompt})


    if parsed.path == "/api/translate/text":
        from api.translate_ws import handle_text
        return handle_text(handler, body)


    if parsed.path == "/api/btw":
        return _handle_btw(handler, body)

    if parsed.path == "/api/background":
        return _handle_background(handler, body)

    if parsed.path == "/api/goal":
        return _handle_goal_command(handler, body)

    if parsed.path == "/api/chat/start":
        # plan 5.1 — POST /api/chat/start?stream=1 (or an SSE Accept header)
        # streams the turn's SSE events on this same chunked response instead
        # of requiring a separate GET /api/stream round trip. Backward
        # compatible: omit both and you get the original plain-JSON response.
        want_stream = (
            parse_qs(parsed.query or "").get("stream", [""])[0] in ("1", "true", "yes")
            or "text/event-stream" in (handler.headers.get("Accept") or "")
        )
        return _handle_chat_start(handler, body, diag=diag, stream=want_stream)

    if parsed.path == "/api/chat":
        return _handle_chat_sync(handler, body)

    if parsed.path == "/api/chat/steer":
        from api.streaming import _handle_chat_steer
        return _handle_chat_steer(handler, body)

    if parsed.path == "/api/terminal/start":
        return _handle_terminal_start(handler, body)

    if parsed.path == "/api/terminal/input":
        return _handle_terminal_input(handler, body)

    if parsed.path == "/api/terminal/resize":
        return _handle_terminal_resize(handler, body)

    if parsed.path == "/api/terminal/close":
        return _handle_terminal_close(handler, body)

    # ── Cron API (POST) ──
    # See GET-side comment above: wrap in cron_profile_context so writes go
    # to the TLS-active profile's jobs.json instead of the process default.
    if parsed.path == "/api/crons/create":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_create(handler, body)

    if parsed.path == "/api/crons/update":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_update(handler, body)

    if parsed.path == "/api/crons/delete":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_delete(handler, body)

    if parsed.path == "/api/crons/run":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_run(handler, body)

    if parsed.path == "/api/crons/pause":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_pause(handler, body)

    if parsed.path == "/api/crons/resume":
        from api.profiles import cron_profile_context

        with cron_profile_context():
            return _handle_cron_resume(handler, body)

    # ── File ops (POST) ──
    if parsed.path == "/api/file/delete":
        return _handle_file_delete(handler, body)

    if parsed.path == "/api/file/save":
        return _handle_file_save(handler, body)

    if parsed.path == "/api/file/create":
        return _handle_file_create(handler, body)

    if parsed.path == "/api/file/rename":
        return _handle_file_rename(handler, body)

    if parsed.path == "/api/file/create-dir":
        return _handle_create_dir(handler, body)

    if parsed.path == "/api/file/reveal":
        return _handle_file_reveal(handler, body)

    if parsed.path == "/api/file/path":
        return _handle_file_path(handler, body)

    # ── Workspace management (POST) ──
    if parsed.path == "/api/workspaces/add":
        return _handle_workspace_add(handler, body)

    if parsed.path == "/api/workspaces/remove":
        return _handle_workspace_remove(handler, body)

    if parsed.path == "/api/workspaces/rename":
        return _handle_workspace_rename(handler, body)

    if parsed.path == "/api/workspaces/reorder":
        return _handle_workspace_reorder(handler, body)

    # ── Commands (POST) ──
    if parsed.path == "/api/commands/exec":
        from api.commands import execute_plugin_command

        command = str(body.get("command", "") or "").strip()
        if not command:
            return bad(handler, "command is required")
        try:
            return j(handler, {"output": execute_plugin_command(command)})
        except ValueError as e:
            return bad(handler, str(e), 400)
        except KeyError:
            return bad(handler, "Plugin command not found", 404)
        except RuntimeError as e:
            return bad(handler, _sanitize_error(e), 500)

    # ── Skills (POST) ──
    if parsed.path == "/api/skills/save":
        return _handle_skill_save(handler, body)

    if parsed.path == "/api/skills/delete":
        return _handle_skill_delete(handler, body)

    # ── Memory (POST) ──
    if parsed.path == "/api/memory/write":
        return _handle_memory_write(handler, body)

    # ── Code-Memory API (POST) ──
    if parsed.path == "/api/code-memory/register":
        return _handle_code_memory_register(handler, body)
    if parsed.path == "/api/code-memory/write":
        return _handle_code_memory_write(handler, body)
    if parsed.path == "/api/code-memory/delete":
        return _handle_code_memory_delete(handler, body)
    if parsed.path == "/api/code-memory/delete-entry":
        return _handle_code_memory_delete_entry(handler, body)
    if parsed.path == "/api/code-memory/update":
        return _handle_code_memory_update(handler, body)
    if parsed.path == "/api/notify":
        return _handle_notify(handler, body)

    # ── Photon (iMessage) provider setup (POST) ──
    if parsed.path == "/api/integrations/photon":
        from api.photon_config import probe_sidecar, reload_sidecar, set_photon_config

        result = set_photon_config(body)
        if not result.get("ok"):
            return bad(handler, result.get("error", "Failed to save Photon config"))
        # Hot-reload the sidecar so the just-saved creds take effect immediately
        # (no manual restart), then report its post-reload state.
        result["reloaded"] = reload_sidecar()
        result["sidecar"] = probe_sidecar()
        return j(handler, result)

    # ── Profile API (POST) ──
    if parsed.path == "/api/profile/switch":
        name = body.get("name", "").strip()
        if not name:
            return bad(handler, "name is required")
        try:
            from api.profiles import switch_profile, _validate_profile_name
            from api.helpers import build_profile_cookie
            if name != 'default':
                _validate_profile_name(name)
            # process_wide=False: don't mutate the process-global _active_profile.
            # Per-client profile is managed via cookie + thread-local (#798).
            result = switch_profile(name, process_wide=False)
            # Invalidate the models cache so the very next /api/models request
            # rebuilds from the new profile's config.yaml rather than returning
            # the old profile's cached model list (#1200 — profile-switch model bug).
            from api.config import invalidate_models_cache
            invalidate_models_cache()
            return j(handler, result, extra_headers={
                'Set-Cookie': build_profile_cookie(name),
            })
        except (ValueError, FileNotFoundError) as e:
            return bad(handler, _sanitize_error(e), 404)
        except RuntimeError as e:
            return bad(handler, str(e), 409)

    if parsed.path == "/api/profile/create":
        name = body.get("name", "").strip()
        if not name:
            return bad(handler, "name is required")
        import re as _re

        if not _re.match(r"^[a-z0-9][a-z0-9_-]{0,63}$", name):
            return bad(
                handler,
                "Invalid profile name: lowercase letters, numbers, hyphens, underscores only",
            )
        clone_from = body.get("clone_from")
        if clone_from is not None:
            clone_from = str(clone_from).strip()
            if not _re.match(r"^[a-z0-9][a-z0-9_-]{0,63}$", clone_from):
                return bad(handler, "Invalid clone_from name")
        base_url = body.get("base_url", "").strip() if body.get("base_url") else None
        api_key = body.get("api_key", "").strip() if body.get("api_key") else None
        default_model = body.get("default_model", "").strip() if body.get("default_model") else None
        model_provider = body.get("model_provider", "").strip() if body.get("model_provider") else None
        if base_url and not base_url.startswith(("http://", "https://")):
            return bad(handler, "base_url must start with http:// or https://")
        try:
            from api.profiles import create_profile_api

            result = create_profile_api(
                name,
                clone_from=clone_from,
                clone_config=bool(body.get("clone_config", False)),
                base_url=base_url,
                api_key=api_key,
                default_model=default_model,
                model_provider=model_provider,
            )
            return j(handler, {"ok": True, "profile": result})
        except (ValueError, FileExistsError, RuntimeError) as e:
            return bad(handler, str(e))

    if parsed.path == "/api/profile/delete":
        name = body.get("name", "").strip()
        if not name:
            return bad(handler, "name is required")
        try:
            from api.profiles import delete_profile_api, _validate_profile_name

            _validate_profile_name(name)
            result = delete_profile_api(name)
            return j(handler, result)
        except (ValueError, FileNotFoundError) as e:
            return bad(handler, _sanitize_error(e))
        except RuntimeError as e:
            return bad(handler, str(e), 409)

    # ── Settings (POST) ──
    if parsed.path == "/api/settings":
        from api.auth import (
            create_session,
            is_auth_enabled,
            parse_cookie,
            set_auth_cookie,
            verify_session,
        )

        if "bot_name" in body:
            body["bot_name"] = (str(body["bot_name"]) or "").strip() or "JarvisCopilot"

        auth_enabled_before = is_auth_enabled()
        current_cookie = parse_cookie(handler)
        logged_in_before = bool(current_cookie and verify_session(current_cookie))
        requested_password = bool(
            isinstance(body.get("_set_password"), str)
            and body.get("_set_password", "").strip()
        )
        requested_clear_password = bool(body.get("_clear_password"))

        # #1560: HERMES_WEBUI_PASSWORD env var takes precedence in
        # api.auth.get_password_hash(), so writing password_hash to settings.json
        # has no effect on auth. Refuse loudly with 409 instead of silently
        # succeeding — the previous behaviour returned 200 + a green save toast
        # while every subsequent login still required the env-var password.
        if requested_password or requested_clear_password:
            if os.getenv("HERMES_WEBUI_PASSWORD", "").strip():
                return bad(
                    handler,
                    "HERMES_WEBUI_PASSWORD env var is set — it overrides the settings password. "
                    "Unset the env var and restart the server before changing the password here.",
                    409,
                )

        saved = save_settings(body)
        saved.pop("password_hash", None)  # never expose hash to client

        auth_enabled_after = is_auth_enabled()
        auth_just_enabled = bool(
            requested_password and auth_enabled_after and not auth_enabled_before
        )
        logged_in_after = logged_in_before
        new_cookie = None

        if auth_just_enabled and not logged_in_before:
            new_cookie = create_session()
            logged_in_after = True

        saved["auth_enabled"] = auth_enabled_after
        saved["logged_in"] = logged_in_after
        saved["auth_just_enabled"] = auth_just_enabled

        if not new_cookie:
            return j(handler, saved)

        response_body = json.dumps(saved, ensure_ascii=False, indent=2).encode("utf-8")
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(response_body)))
        handler.send_header("Cache-Control", "no-store")
        set_auth_cookie(handler, new_cookie)
        _security_headers(handler)
        handler.end_headers()
        handler.wfile.write(response_body)
        return True

    if parsed.path == "/api/onboarding/oauth/start":
        from api.auth import is_auth_enabled
        import os as _os
        if not is_auth_enabled() and not _os.getenv("HERMES_WEBUI_ONBOARDING_OPEN"):
            import ipaddress
            try:
                _xff = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                _xri = handler.headers.get("X-Real-IP", "").strip()
                _raw = handler.client_address[0]
                addr = ipaddress.ip_address(_xff or _xri or _raw)
                is_local = addr.is_loopback or addr.is_private
            except ValueError:
                is_local = False
            if not is_local:
                return bad(handler, "Onboarding OAuth is only available from local networks when auth is not enabled. To bypass this on a remote server, set HERMES_WEBUI_ONBOARDING_OPEN=1.", 403)
        try:
            return j(handler, start_onboarding_oauth_flow(body), extra_headers={"Cache-Control": "no-store"})
        except ValueError as e:
            return bad(handler, str(e))
        except RuntimeError as e:
            return bad(handler, str(e), 500)

    if parsed.path == "/api/onboarding/oauth/cancel":
        try:
            return j(handler, cancel_onboarding_oauth_flow(body), extra_headers={"Cache-Control": "no-store"})
        except ValueError as e:
            return bad(handler, str(e))

    if parsed.path == "/api/onboarding/setup":
        # Writing API keys to disk - restrict to local/private networks unless auth is active.
        # In Docker, requests arrive from the bridge network (172.x.x.x), not 127.0.0.1,
        # even when the user accesses via localhost:8787 on the host.
        # Behind a reverse proxy (nginx/Caddy/Traefik) or SSH tunnel, X-Forwarded-For
        # carries the real origin IP — read it first before falling back to the raw socket addr.
        # HERMES_WEBUI_ONBOARDING_OPEN=1 lets operators on remote servers explicitly bypass
        # the check when they control network access themselves (e.g. firewall + VPN).
        from api.auth import is_auth_enabled
        import os as _os
        if not is_auth_enabled() and not _os.getenv("HERMES_WEBUI_ONBOARDING_OPEN"):
            import ipaddress
            try:
                # Prefer forwarded headers set by reverse proxies
                _xff = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                _xri = handler.headers.get("X-Real-IP", "").strip()
                _raw = handler.client_address[0]
                _ip_str = _xff or _xri or _raw
                addr = ipaddress.ip_address(_ip_str)
                is_local = addr.is_loopback or addr.is_private
            except ValueError:
                is_local = False
            if not is_local:
                return bad(handler, "Onboarding setup is only available from local networks when auth is not enabled. To bypass this on a remote server, set HERMES_WEBUI_ONBOARDING_OPEN=1.", 403)
        try:
            return j(handler, apply_onboarding_setup(body))
        except ValueError as e:
            return bad(handler, str(e))
        except RuntimeError as e:
            return bad(handler, str(e), 500)

    if parsed.path == "/api/onboarding/complete":
        return j(handler, complete_onboarding())

    if parsed.path == "/api/onboarding/probe":
        # Probe a self-hosted provider endpoint (#1499).  Validates the
        # configured base URL is reachable + parses /models, returns the
        # model catalog so the wizard can populate its dropdown.
        # Read-only: no config.yaml or .env writes happen here.  Same local-
        # network gate as /api/onboarding/setup (also writing-adjacent in
        # spirit because it carries an api_key the user typed).
        from api.auth import is_auth_enabled
        import os as _os
        if not is_auth_enabled() and not _os.getenv("HERMES_WEBUI_ONBOARDING_OPEN"):
            import ipaddress
            try:
                _xff = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                _xri = handler.headers.get("X-Real-IP", "").strip()
                _raw = handler.client_address[0]
                _ip_str = _xff or _xri or _raw
                addr = ipaddress.ip_address(_ip_str)
                is_local = addr.is_loopback or addr.is_private
            except ValueError:
                is_local = False
            if not is_local:
                return bad(handler, "Onboarding probe is only available from local networks when auth is not enabled. To bypass this on a remote server, set HERMES_WEBUI_ONBOARDING_OPEN=1.", 403)
        provider = str((body or {}).get("provider") or "").strip().lower()
        base_url = str((body or {}).get("base_url") or "")
        api_key = str((body or {}).get("api_key") or "").strip() or None
        try:
            return j(handler, probe_provider_endpoint(provider, base_url, api_key))
        except Exception as e:
            return bad(handler, f"probe failed: {e}", 500)


    # ── Project CRUD (POST) ──
    if parsed.path == "/api/projects/create":
        need(body, "name")
        import re as _re
        from api.profiles import get_active_profile_name

        name = body["name"].strip()[:128]
        if not name:
            return bad(handler, "name required")
        color = body.get("color")
        if color and not _re.match(r"^#[0-9a-fA-F]{3,8}$", color):
            return bad(handler, "Invalid color format")
        projects = load_projects()
        proj = {
            "project_id": uuid.uuid4().hex[:12],
            "name": name,
            "color": color,
            "profile": get_active_profile_name() or 'default',
            "created_at": time.time(),
        }
        projects.append(proj)
        save_projects(projects)
        return j(handler, {"ok": True, "project": proj})

    if parsed.path == "/api/projects/rename":
        need(body, "project_id", "name")
        import re as _re
        from api.profiles import get_active_profile_name

        projects = load_projects()
        proj = next(
            (p for p in projects if p["project_id"] == body["project_id"]), None
        )
        if not proj:
            return bad(handler, "Project not found", 404)
        # #1614: a project can only be renamed by the profile that owns it.
        active_profile = get_active_profile_name()
        if not _profiles_match(proj.get("profile"), active_profile):
            return bad(handler, "Project not found", 404)
        proj["name"] = body["name"].strip()[:128]
        if "color" in body:
            color = body["color"]
            if color and not _re.match(r"^#[0-9a-fA-F]{3,8}$", color):
                return bad(handler, "Invalid color format")
            proj["color"] = color
        save_projects(projects)
        return j(handler, {"ok": True, "project": proj})

    if parsed.path == "/api/projects/delete":
        need(body, "project_id")
        from api.profiles import get_active_profile_name
        projects = load_projects()
        proj = next(
            (p for p in projects if p["project_id"] == body["project_id"]), None
        )
        if not proj:
            return bad(handler, "Project not found", 404)
        # #1614: a project can only be deleted by the profile that owns it.
        active_profile = get_active_profile_name()
        if not _profiles_match(proj.get("profile"), active_profile):
            return bad(handler, "Project not found", 404)
        projects = [p for p in projects if p["project_id"] != body["project_id"]]
        save_projects(projects)
        # Unassign all sessions that belonged to this project
        if SESSION_INDEX_FILE.exists():
            try:
                index = json.loads(SESSION_INDEX_FILE.read_text(encoding="utf-8"))
                for entry in index:
                    if entry.get("project_id") == body["project_id"]:
                        try:
                            s = get_session(entry["session_id"])
                            s.project_id = None
                            s.save()
                        except Exception:
                            logger.debug("Failed to update session %s", entry.get("session_id"))
            except Exception:
                logger.debug("Failed to load session index for project unlink")
        return j(handler, {"ok": True})


    # ── Self-update (POST) ──
    if parsed.path == "/api/updates/apply":
        target = body.get("target", "")
        if target not in ("webui", "agent"):
            return bad(handler, 'target must be "webui" or "agent"')
        from api.updates import apply_update

        return j(handler, apply_update(target))

    if parsed.path == "/api/updates/force":
        target = body.get("target", "")
        if target not in ("webui", "agent"):
            return bad(handler, 'target must be "webui" or "agent"')
        from api.updates import apply_force_update

        return j(handler, apply_force_update(target))

    if parsed.path == "/api/updates/summary":
        from api.updates import summarize_update_payload

        updates = body.get("updates") if isinstance(body, dict) else {}
        target = body.get("target") if isinstance(body, dict) else None

        def _llm_update_summary(system_prompt: str, user_prompt: str) -> str:
            from api import profiles as profiles_api

            active_profile = profiles_api.get_active_profile_name() or "default"

            with profiles_api.profile_env_for_background_worker(
                active_profile,
                "update summary",
                logger_override=logger,
            ):
                from api.config import get_effective_default_model, resolve_model_provider

                messages = [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ]

                _main_model, _main_provider, _main_base_url = resolve_model_provider(get_effective_default_model())
                from api.oauth import runtime_credentials
                _main_api_key, _main_provider, _main_base_url = runtime_credentials(
                    _main_provider, _main_base_url, what="update summary")

                main_runtime = {
                    "provider": _main_provider,
                    "model": _main_model,
                    "base_url": _main_base_url,
                    "api_key": _main_api_key,
                }

                try:
                    from agent.auxiliary_client import get_text_auxiliary_client

                    # Update summaries are a short text-compression/summarization task.
                    # Reuse the documented auxiliary.compression slot instead of
                    # inventing a WebUI-only auxiliary task name that users cannot
                    # discover in the JarvisCopilot setup/config UI.
                    aux_client, aux_model = get_text_auxiliary_client(
                        "compression",
                        main_runtime=main_runtime,
                    )
                    if aux_client is not None and aux_model:
                        response = aux_client.chat.completions.create(
                            model=aux_model,
                            messages=messages,
                        )
                        return str(response.choices[0].message.content or "").strip()
                except Exception as _e:
                    logger.debug("update summary auxiliary model failed; falling back to main model: %s", _e)

                from run_agent import AIAgent

                agent = AIAgent(
                    model=_main_model,
                    provider=_main_provider,
                    base_url=_main_base_url,
                    api_key=_main_api_key,
                    platform="webui",
                    quiet_mode=True,
                    enabled_toolsets=[],
                    session_id=f"updates-summary-{uuid.uuid4().hex[:8]}",
                )
                result = agent.run_conversation(
                    user_message=user_prompt,
                    system_message=system_prompt,
                    conversation_history=[],
                    task_id=f"updates-summary-{uuid.uuid4().hex[:8]}",
                )
                return str(result.get("final_response") or "").strip()

        return j(handler, summarize_update_payload(updates, llm_callback=_llm_update_summary, target=target))


    # ── Auth endpoints (POST) ──
    if parsed.path == "/api/auth/login":
        from api.auth import (
            verify_password,
            create_session,
            set_auth_cookie,
            is_auth_enabled,
        )
        from api.auth import _check_login_rate, _record_login_attempt

        if not is_auth_enabled():
            return j(handler, {"ok": True, "message": "Auth not enabled"})
        client_ip = handler.client_address[0]
        if not _check_login_rate(client_ip):
            return j(
                handler,
                {"error": "Too many attempts. Try again in a minute."},
                status=429,
            )
        password = body.get("password", "")
        if not verify_password(password):
            _record_login_attempt(client_ip)
            return bad(handler, "Invalid password", 401)
        cookie_val = create_session()
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Cache-Control", "no-store")
        _security_headers(handler)
        set_auth_cookie(handler, cookie_val)
        handler.end_headers()
        handler.wfile.write(json.dumps({"ok": True}).encode())
        return True

    if parsed.path.startswith("/api/forms/"):
        from api.forms import handle_post as _forms_post

        if _forms_post(handler, parsed, body):
            return True

    if parsed.path == "/api/integrations/setup/start":
        from api.integration_setup import handle_post as _setup_post

        if _setup_post(handler, parsed, body):
            return True

    if "/health" in parsed.path:
        from api.health_routes import handle_post as _health_post

        if _health_post(handler, parsed, body):
            return True

    if parsed.path.startswith("/api/imessage-memory"):
        from api.imessage_memory_routes import handle_post as _imessage_memory_post

        if _imessage_memory_post(handler, parsed, body):
            return True

    if parsed.path == "/api/integrations" or parsed.path.startswith("/api/integrations/"):
        from api.integrations_routes import handle_post as _integrations_post, is_ui_path
        from api.profiles import cron_profile_context

        if is_ui_path(parsed.path):
            # A UI action runs a script; see the GET side for why it skips the cron lock.
            if _integrations_post(handler, parsed, body):
                return True
        else:
            # Wrapped like every other cron entry point: these read and write
            # jobs.json through cron.jobs, which resolves the profile at call time.
            with cron_profile_context():
                if _integrations_post(handler, parsed, body):
                    return True

    # ── JarvisCopilot pairing claim (POST) ──
    # Public endpoint — must be reachable without a session so a fresh
    # device can complete the handshake. Rate-limited per IP using the
    # same _check_login_rate machinery as password login.
    if parsed.path == "/api/auth/pair/claim":
        from api.auth import (
            create_session,
            set_auth_cookie,
            _check_login_rate,
            _record_login_attempt,
        )
        from api.pairing import claim_pairing_code

        client_ip = handler.client_address[0]
        if not _check_login_rate(client_ip):
            return j(
                handler,
                {"error": "Too many attempts. Try again in a minute."},
                status=429,
            )
        code = (body.get("code") or "").strip()
        device_name = (body.get("name") or "").strip()
        ua = handler.headers.get("User-Agent", "")
        # claim_pairing_code() returns the session cookie value on success,
        # None on bad/expired/already-claimed code.
        cookie_val = claim_pairing_code(
            code,
            device_name=device_name,
            device_ip=client_ip,
            user_agent=ua,
        )
        if not cookie_val:
            _record_login_attempt(client_ip)
            return bad(handler, "Invalid or expired pairing code", 401)
        # If a Cloudflare Access service token is configured for the tunnel,
        # hand it to the freshly-paired device so its native (non-browser)
        # requests can clear Access at the edge. Omitted when unconfigured, so
        # local / non-tunnel pairing is unchanged.
        resp_payload = {"ok": True}
        try:
            from edge import get_manager  # webui/ is on sys.path
            cf = get_manager().cf_service_token_for_pairing()
            if cf.get("client_id") and cf.get("client_secret"):
                resp_payload["cf_access"] = {
                    "client_id": cf["client_id"],
                    "client_secret": cf["client_secret"],
                }
        except Exception:
            logger.debug("CF service token unavailable for pairing payload", exc_info=True)
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Cache-Control", "no-store")
        _security_headers(handler)
        set_auth_cookie(handler, cookie_val)
        handler.end_headers()
        handler.wfile.write(json.dumps(resp_payload).encode())
        return True

    if parsed.path == "/api/auth/logout":
        from api.auth import clear_auth_cookie, invalidate_session, parse_cookie

        cookie_val = parse_cookie(handler)
        if cookie_val:
            invalidate_session(cookie_val)
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Cache-Control", "no-store")
        _security_headers(handler)
        clear_auth_cookie(handler)
        handler.end_headers()
        handler.wfile.write(json.dumps({"ok": True}).encode())
        return True

    # ── Checkpoints / Rollback (POST) ──
    if parsed.path == "/api/rollback/restore":
        if not body:
            return bad(handler, "request body is required")
        workspace = body.get("workspace", "")
        checkpoint = body.get("checkpoint", "")
        if not workspace or not checkpoint:
            return bad(handler, "workspace and checkpoint are required")
        try:
            from api.rollback import restore_checkpoint
            return j(handler, restore_checkpoint(workspace, checkpoint))
        except ValueError as e:
            return bad(handler, str(e))
        except Exception as e:
            logger.exception("rollback/restore failed")
            return bad(handler, str(e), status=500)

    return False  # 404


def handle_patch(handler, parsed) -> bool:
    """Handle all PATCH routes. Returns True if handled, False for 404."""
    if not check_csrf(handler):
        return j(handler, {"error": "Cross-origin request rejected"}, status=403)
    return dispatch_mount(Request(handler, parsed, "PATCH"))


def handle_put(handler, parsed) -> bool:
    """Handle all PUT routes. Returns True if handled, False for 404."""
    if not check_csrf(handler):
        return j(handler, {"error": "Cross-origin request rejected"}, status=403)
    req = Request(handler, parsed, "PUT")
    if dispatch_mount(req):
        return True
    if parsed.path == "/api/web/config":
        from api.web_config import handle_web_config_put
        if handle_web_config_put(handler, parsed, req.body):
            return True
    return False


def handle_delete(handler, parsed) -> bool:
    """Handle all DELETE routes. Returns True if handled, False for 404."""
    if not check_csrf(handler):
        return j(handler, {"error": "Cross-origin request rejected"}, status=403)
    req = Request(handler, parsed, "DELETE")
    if dispatch_mount(req):
        return True
    body = req.body
    if parsed.path.startswith("/api/integrations/"):
        from api.integrations_routes import handle_delete as _integrations_delete
        from api.profiles import cron_profile_context

        # Wrapped like every other cron entry point: these read and write
        # jobs.json through cron.jobs, which resolves the profile at call time.
        with cron_profile_context():
            # The body names which parts to remove; absent means all of it.
            if _integrations_delete(handler, parsed, body):
                return True

    return False

# ── GET route helpers ─────────────────────────────────────────────────────────

# MIME types for static file serving. Hoisted to module scope to avoid
# rebuilding the dict on every request.
_STATIC_MIME = {
    "css": "text/css",
    "js": "application/javascript",
    "html": "text/html",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "ico": "image/x-icon",
    "gif": "image/gif",
    "webp": "image/webp",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "ttf": "font/ttf",
}
# MIME types that are text-based and should carry charset=utf-8
_TEXT_MIME_TYPES = {"text/css", "application/javascript", "text/html", "image/svg+xml", "text/plain"}

# Static assets used to go out uncompressed with no-store, so every page load
# re-downloaded ~5.5 MB. A URL carrying the running build's ?v= never changes
# content, so it may be cached for good; anything else revalidates against an
# ETag (a 304 is a few hundred bytes). Text types are gzipped once per file
# version and kept, ~2 MB for the whole static tree.
_STATIC_GZIP_TYPES = _TEXT_MIME_TYPES | {"font/ttf", "application/json"}
_STATIC_GZIP_MIN_BYTES = 1024
_STATIC_GZIP_MAX_ENTRIES = 256
_STATIC_GZIP_CACHE: dict = {}  # path -> (etag, gzipped bytes or None when too small)
_STATIC_GZIP_LOCK = threading.Lock()


def _static_cache_control(parsed) -> str:
    from api.updates import WEBUI_VERSION

    version = parse_qs(parsed.query).get("v", [""])[0]
    # A dirty (developer) tree can change a file without a restart, which keeps
    # the same ?v= -- revalidate there instead.
    if version and version == WEBUI_VERSION and "dirty" not in WEBUI_VERSION.lower():
        return "public, max-age=31536000, immutable"
    return "no-cache"


def _static_etag_matches(handler, etag: str) -> bool:
    headers = getattr(handler, "headers", None)
    sent = headers.get("If-None-Match", "") if headers else ""
    if not sent:
        return False
    tags = {tag.strip() for tag in str(sent).split(",")}
    return "*" in tags or etag in tags or etag[2:] in tags


def _static_gzip(static_file: Path, etag: str):
    key = str(static_file)
    with _STATIC_GZIP_LOCK:
        cached = _STATIC_GZIP_CACHE.get(key)
    if cached is not None and cached[0] == etag:
        return cached[1]
    raw = static_file.read_bytes()
    body = None
    if len(raw) >= _STATIC_GZIP_MIN_BYTES:
        import gzip

        body = gzip.compress(raw, compresslevel=6)
    with _STATIC_GZIP_LOCK:
        if len(_STATIC_GZIP_CACHE) >= _STATIC_GZIP_MAX_ENTRIES and key not in _STATIC_GZIP_CACHE:
            _STATIC_GZIP_CACHE.clear()
        _STATIC_GZIP_CACHE[key] = (etag, body)
    return body


def _serve_static(handler, parsed):
    static_root = (Path(__file__).parent.parent / "static").resolve()
    # Strip the leading '/static/' prefix, then resolve and sandbox
    rel = parsed.path[len("/static/") :]
    static_file = (static_root / rel).resolve()
    try:
        static_file.relative_to(static_root)
    except ValueError:
        return j(handler, {"error": "not found"}, status=404)
    if not static_file.exists() or not static_file.is_file():
        return j(handler, {"error": "not found"}, status=404)
    ext = static_file.suffix.lower()
    ct = _STATIC_MIME.get(ext.lstrip("."), "text/plain")
    ct_header = f"{ct}; charset=utf-8" if ct in _TEXT_MIME_TYPES else ct
    stat = static_file.stat()
    etag = f'W/"{stat.st_mtime_ns:x}-{stat.st_size:x}"'
    cache_control = _static_cache_control(parsed)
    compressible = ct in _STATIC_GZIP_TYPES
    if _static_etag_matches(handler, etag):
        handler.send_response(304)
        handler.send_header("ETag", etag)
        handler.send_header("Cache-Control", cache_control)
        if compressible:
            handler.send_header("Vary", "Accept-Encoding")
        handler.end_headers()
        return True
    from api.helpers import _accepts_gzip

    body = None
    if compressible and _accepts_gzip(handler):
        body = _static_gzip(static_file, etag)
    gzipped = body is not None
    if body is None:
        body = static_file.read_bytes()
    handler.send_response(200)
    handler.send_header("Content-Type", ct_header)
    handler.send_header("Cache-Control", cache_control)
    handler.send_header("ETag", etag)
    if compressible:
        handler.send_header("Vary", "Accept-Encoding")
    if gzipped:
        handler.send_header("Content-Encoding", "gzip")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
    return True


def _handle_list_dir(handler, parsed):
    qs = parse_qs(parsed.query)
    sid = qs.get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id is required")
    try:
        s = get_session(sid)
        workspace = s.workspace
    except KeyError:
        # Fallback for CLI sessions not loaded in WebUI memory
        try:
            cli_meta = None
            for cs in get_cli_sessions():
                if cs["session_id"] == sid:
                    cli_meta = cs
                    break
            if not cli_meta:
                return bad(handler, "Session not found", 404)
            workspace = cli_meta.get("workspace", "")
        except Exception:
            return bad(handler, "Session not found", 404)
    try:
        return j(
            handler,
            {
                "entries": list_dir(Path(workspace), qs.get("path", ["."])[0]),
                "path": qs.get("path", ["."])[0],
            },
        )
    except (FileNotFoundError, ValueError) as e:
        return bad(handler, _sanitize_error(e), 404)


def _sse_with_id(handler, event, data, event_id=None):
    if event_id:
        handler.wfile.write(f"id: {event_id}\n".encode("utf-8"))
    sse.send(handler, event, data)


def _parse_run_journal_after_seq(qs: dict) -> int | None:
    raw = qs.get("after_seq", [None])[0]
    if raw in (None, ""):
        return None
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return 0


def _replay_run_journal(handler, stream_id: str, after_seq: int | None) -> bool:
    summary = find_run_summary(stream_id)
    if not summary:
        return False
    journal = read_run_events(
        str(summary.get("session_id") or ""),
        stream_id,
        after_seq=after_seq,
    )
    for entry in journal.get("events") or []:
        _sse_with_id(
            handler,
            entry.get("event") or entry.get("type") or "message",
            entry.get("payload"),
            entry.get("event_id"),
        )
    if not summary.get("terminal"):
        stale = stale_interrupted_event(
            str(summary.get("session_id") or ""),
            stream_id,
            after_seq=after_seq,
        )
        if stale:
            _sse_with_id(handler, stale["event"], stale["payload"], stale["event_id"])
    return True


def _handle_sse_stream(handler, parsed):
    qs = parse_qs(parsed.query)
    stream_id = qs.get("stream_id", [""])[0]
    stream = STREAMS.get(stream_id)
    if stream is None:
        try:
            journal_available = bool(find_run_summary(stream_id)) if stream_id else False
        except Exception:
            journal_available = False
        if not journal_available:
            return j(handler, {"error": "stream not found"}, status=404)
        sse.open_stream(handler)
        try:
            _replay_run_journal(handler, stream_id, _parse_run_journal_after_seq(qs))
        except sse.CLIENT_GONE:
            pass
        return True
    _send_sse_headers(handler)
    try:
        _pump_sse_stream(handler, stream_id, stream)
    except sse.CLIENT_GONE:
        pass
    return True


def _send_sse_headers(handler) -> None:
    sse.open_stream(handler)


def _pump_sse_stream(handler, stream_id: str, stream) -> None:
    """Write live subscriber events for `stream_id` as SSE frames until a
    terminal event (stream_end/error/cancel). Shared by the GET
    ``/api/stream`` endpoint and the plan-5.1 same-response
    ``POST /api/chat/start?stream=1`` path — both attach to the SAME
    ``STREAMS[stream_id]`` channel the worker thread publishes to, so either
    can pick up mid-stream if the other's connection drops.
    """
    subscriber = stream.subscribe() if hasattr(stream, "subscribe") else stream
    try:
        while True:
            try:
                event, data = subscriber.get(timeout=sse.HEARTBEAT_SECONDS)
            except queue.Empty:
                handler.wfile.write(b": heartbeat\n\n")
                handler.wfile.flush()
                continue
            # Stage-364: emit `id:` from STREAM_LAST_EVENT_ID side-channel so
            # the frontend's `_lastRunJournalSeq` cursor advances during live
            # streaming. Without this, mid-stream error→replay would arrive
            # with after_seq=0 and double-render every journaled event.
            event_id = STREAM_LAST_EVENT_ID.get(stream_id)
            if event_id:
                _sse_with_id(handler, event, data, event_id)
            else:
                sse.send(handler, event, data)
            if event in ("stream_end", "error", "cancel"):
                break
    finally:
        if subscriber is not stream and hasattr(stream, "unsubscribe"):
            try:
                stream.unsubscribe(subscriber)
            except Exception:
                pass


def _stream_chat_start_response(handler, response: dict) -> bool:
    """plan 5.1 — collapse chat/start + the SSE GET into one chunked response.

    Writes the normal chat/start JSON payload as the first SSE event (event
    name ``chat_start``, carrying the same fields the plain POST would have
    returned: stream_id, session_id, title, ...) so a client that adopted
    this path never needs the separate GET round trip, then pumps the rest
    of the turn's events on the SAME connection. The stream stays registered
    in STREAMS regardless (the worker thread doesn't know or care how many
    listeners it has), so a client whose POST connection drops can still
    fall back to ``GET /api/stream?stream_id=...`` exactly as before.
    """
    stream_id = response.get("stream_id")
    stream = STREAMS.get(stream_id) if stream_id else None
    _send_sse_headers(handler)
    try:
        sse.send(handler, "chat_start", response)
        if stream is not None:
            _pump_sse_stream(handler, stream_id, stream)
    except sse.CLIENT_GONE:
        pass
    return True


def _terminal_session_and_workspace(body_or_query):
    sid = str(body_or_query.get("session_id", "")).strip()
    if not sid:
        raise ValueError("session_id required")
    try:
        s = get_session(sid)
    except KeyError:
        raise KeyError("Session not found")
    workspace = resolve_trusted_workspace(getattr(s, "workspace", "") or "")
    return sid, workspace


def _handle_terminal_start(handler, body):
    try:
        sid, workspace = _terminal_session_and_workspace(body)
        from api.terminal import start_terminal
        term = start_terminal(
            sid,
            workspace,
            rows=int(body.get("rows") or 24),
            cols=int(body.get("cols") or 80),
            restart=bool(body.get("restart")),
        )
        return j(
            handler,
            {
                "ok": True,
                "session_id": sid,
                "workspace": term.workspace,
                "running": term.is_alive(),
            },
        )
    except KeyError as e:
        return bad(handler, str(e), 404)
    except ValueError as e:
        return bad(handler, str(e), 400)
    except Exception as e:
        return bad(handler, _sanitize_error(e), 500)


def _handle_terminal_input(handler, body):
    try:
        require(body, "session_id")
        data = str(body.get("data", ""))
        if len(data) > 8192:
            return bad(handler, "input too large", 413)
        from api.terminal import write_terminal
        write_terminal(body["session_id"], data)
        return j(handler, {"ok": True})
    except KeyError as e:
        return bad(handler, str(e), 404)
    except ValueError as e:
        return bad(handler, str(e), 400)
    except Exception as e:
        return bad(handler, _sanitize_error(e), 500)


def _handle_terminal_resize(handler, body):
    try:
        require(body, "session_id")
        from api.terminal import resize_terminal
        resize_terminal(
            body["session_id"],
            rows=int(body.get("rows") or 24),
            cols=int(body.get("cols") or 80),
        )
        return j(handler, {"ok": True})
    except KeyError as e:
        return bad(handler, str(e), 404)
    except ValueError as e:
        return bad(handler, str(e), 400)
    except Exception as e:
        return bad(handler, _sanitize_error(e), 500)


def _handle_terminal_close(handler, body):
    try:
        require(body, "session_id")
        from api.terminal import close_terminal
        closed = close_terminal(body["session_id"])
        return j(handler, {"ok": True, "closed": closed})
    except ValueError as e:
        return bad(handler, str(e), 400)


def _handle_terminal_output(handler, parsed):
    qs = parse_qs(parsed.query)
    sid = qs.get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id required")
    from api.terminal import get_terminal
    term = get_terminal(sid)
    if term is None:
        return j(handler, {"error": "terminal not running"}, status=404)

    sse.open_stream(handler)
    try:
        while True:
            try:
                event, data = term.output.get(timeout=sse.HEARTBEAT_SECONDS)
            except queue.Empty:
                handler.wfile.write(b": terminal heartbeat\n\n")
                handler.wfile.flush()
                if term.closed.is_set() and term.output.empty():
                    payload = {"exit_code": term.proc.poll()}
                    reason = getattr(term, "close_reason", None)
                    if reason:
                        payload["reason"] = reason
                    sse.send(handler, "terminal_closed", payload)
                    break
                continue
            # COALESCE a burst of consecutive output frames into ONE SSE write. A
            # busy claude REPL repaints the whole pane, enqueuing many ~8-64KB
            # chunks; emitting one json.dumps + flush per chunk was the dominant
            # source of the "very laggy" terminal. Drain whatever is already
            # queued and concatenate the output text; stop at a control event
            # (terminal_closed/error), which we forward after the merged output.
            if event == "output":
                texts = [(data or {}).get("text", "")]
                ctrl = None
                while True:
                    try:
                        ev2, d2 = term.output.get_nowait()
                    except queue.Empty:
                        break
                    if ev2 == "output":
                        texts.append((d2 or {}).get("text", ""))
                    else:
                        ctrl = (ev2, d2)
                        break
                sse.send(handler, "output", {"text": "".join(texts)})
                if ctrl is not None:
                    sse.send(handler, ctrl[0], ctrl[1])
                    if ctrl[0] in ("terminal_closed", "terminal_error"):
                        break
                continue
            sse.send(handler, event, data)
            if event in ("terminal_closed", "terminal_error"):
                break
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        pass
    return True


def _gateway_sse_probe_payload(settings, watcher):
    enabled = bool(settings.get('show_cli_sessions'))
    # Use the public is_alive() accessor where available (current GatewayWatcher);
    # fall back to the private _thread check for any older in-memory instance
    # that might still be hanging around mid-upgrade, and for test doubles that
    # don't implement the full public API.
    if watcher is None:
        watcher_alive = False
    elif hasattr(watcher, 'is_alive') and callable(getattr(watcher, 'is_alive')):
        watcher_alive = bool(watcher.is_alive())
    else:
        _t = getattr(watcher, '_thread', None)
        watcher_alive = _t is not None and _t.is_alive()
    payload = {
        'enabled': enabled,
        'fallback_poll_ms': 30000,
        'ok': enabled and watcher_alive,
        'watcher_running': watcher_alive,
    }
    if not enabled:
        payload['error'] = 'agent sessions not enabled'
        return payload, 404
    if not watcher_alive:
        payload['error'] = 'watcher not started'
        return payload, 503
    return payload, 200


def _handle_gateway_sse_stream(handler, parsed):
    """SSE endpoint for real-time gateway session updates.
    Streams change events from the gateway watcher background thread.
    Only active when show_cli_sessions (show_agent_sessions) setting is enabled.
    """
    settings = load_settings()

    from api.gateway_watcher import get_watcher
    watcher = get_watcher()

    probe = parse_qs(parsed.query).get('probe', [''])[0].lower() in {'1', 'true', 'yes'}
    if probe:
        payload, status = _gateway_sse_probe_payload(settings, watcher)
        return j(handler, payload, status=status)

    # Check if the feature is enabled
    if not settings.get('show_cli_sessions'):
        return j(handler, {'error': 'agent sessions not enabled'}, status=404)

    # Same watcher_alive semantics as the probe path — centralised via
    # the helper so both branches stay in sync.
    _probe_body, _probe_status = _gateway_sse_probe_payload(settings, watcher)
    if not _probe_body['watcher_running']:
        return j(handler, {'error': 'watcher not started'}, status=503)

    sse.open_stream(handler)

    q = watcher.subscribe()
    try:
        # Send initial snapshot immediately
        from api.models import get_cli_sessions
        initial = get_cli_sessions()
        sse.send(handler, 'sessions_changed', {'sessions': initial})

        while True:
            try:
                event_data = q.get(timeout=sse.HEARTBEAT_SECONDS)
            except queue.Empty:
                sse.keepalive(handler)
                continue
            if event_data is None:
                break  # watcher is stopping
            sse.send(handler, event_data.get('type', 'sessions_changed'), event_data)
    except sse.CLIENT_GONE:
        pass
    finally:
        watcher.unsubscribe(q)
    return True


def _session_events_snapshot(session_id: str) -> dict:
    """What a device needs to catch up the instant it attaches.

    Without this, a client that opens a chat while a run is already in flight
    would sit blank until the NEXT announcement -- which for a run already
    underway never comes. The snapshot hands it the live stream_id and the
    journal cursor, so it can attach and replay the part it missed.
    """
    snap = {'session_id': session_id, 'active_stream_id': None, 'last_seq': 0}
    try:
        # Metadata only: this needs active_stream_id, not the message array,
        # and this runs on every connect and every reconnect.
        s = SESSIONS.get(session_id) or Session.load_metadata_only(session_id)
    except Exception:
        # Session.load returns None for a missing id, so reaching here means a
        # REAL failure: corrupt JSON, a schema mismatch, a disk error. Reporting
        # it as "no active run" is indistinguishable from a genuinely idle
        # session, and the client then sits blank through a turn that is actually
        # streaming, with nothing anywhere to explain why.
        logger.warning("session events: failed to load %s for snapshot",
                       session_id, exc_info=True)
        snap["error"] = "session_load_failed"
        s = None
    stream_id = getattr(s, 'active_stream_id', None) if s is not None else None
    if not stream_id:
        return snap
    with STREAMS_LOCK:
        live = stream_id in STREAMS
    if not live:
        # active_stream_id outlives a worker that died; clear_stale_stream_state
        # repairs it lazily elsewhere, and announcing it here would send the
        # client chasing a stream that is never going to produce another event.
        return snap
    snap['active_stream_id'] = stream_id
    event_id = STREAM_LAST_EVENT_ID.get(stream_id) or ''
    tail = event_id.rsplit(':', 1)[-1] if ':' in event_id else ''
    try:
        snap['last_seq'] = max(0, int(tail))
    except (TypeError, ValueError):
        snap['last_seq'] = 0
    return snap


def _handle_session_events_sse(handler, parsed):
    """SSE: what changed on this session, for every device that has it open.

    Carries pointers, not content. ``run_started`` says "attach to this
    stream_id" and the existing run stream delivers the tokens -- that stream
    already fans out to every subscriber, so the only thing that was ever
    missing is telling the other devices it exists.
    """
    qs = parse_qs(parsed.query)
    session_id = (qs.get('session_id', [''])[0] or '').strip()
    if not session_id:
        return j(handler, {'error': 'session_id required'}, status=400)

    sse.open_stream(handler)

    # Subscribe BEFORE the snapshot: a run starting in between is then delivered
    # as an event rather than falling into the gap between the two.
    q = SESSION_EVENTS.subscribe(session_id)
    try:
        sse.relay(handler, q, greet=('snapshot', _session_events_snapshot(session_id)))
    finally:
        SESSION_EVENTS.unsubscribe(session_id, q)
    return True


def _handle_media(handler, parsed):
    """Serve a local file by absolute path for inline display in the chat.

    Security:
    - Path must resolve to an allowed root (jarviscopilot home, /tmp, common dirs)
    - Auth-gated when auth is enabled
    - Only image MIME types are served inline; all others force download
    - SVG always served as attachment (XSS risk)
    - No path traversal: resolved path must stay within an allowed root
    - Additional roots can be added via MEDIA_ALLOWED_ROOTS env var
      (os.pathsep-separated list of absolute paths; ":" on POSIX, ";" on Windows)
    """
    import os as _os
    from api.auth import is_auth_enabled, parse_cookie, verify_session
    _HOME = Path(_os.path.expanduser("~"))
    _HERMES_HOME = Path(_os.getenv("HERMES_HOME", str(_HOME / ".jarviscopilot"))).expanduser()

    # Auth check
    if is_auth_enabled():
        cv = parse_cookie(handler)
        if not (cv and verify_session(cv)):
            handler.send_response(401)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"Authentication required"}')
            return

    qs = parse_qs(parsed.query)
    raw_path = qs.get("path", [""])[0].strip()
    if not raw_path:
        return bad(handler, "path parameter required", 400)

    # Resolve the path and check it is within an allowed root
    try:
        target = Path(raw_path).resolve()
    except Exception:
        return bad(handler, "Invalid path", 400)

    # Allowed roots: jarviscopilot home, /tmp, and active workspace.
    # Intentionally NOT the entire home dir — that would expose ~/.ssh,
    # ~/.aws, browser profiles, etc. to any authenticated user.
    allowed_roots = [
        _HERMES_HOME.resolve(),
        Path("/tmp").resolve(),
        (_HOME / ".jarviscopilot").resolve(),
    ]
    # Also allow the active workspace directory (where screenshots land)
    try:
        from api.workspace import get_last_workspace
        ws = Path(get_last_workspace()).resolve()
        if ws.is_dir():
            allowed_roots.append(ws)
    except Exception:
        pass

    # Also allow additional roots from MEDIA_ALLOWED_ROOTS env var
    # (os.pathsep-separated list; ":" on POSIX, ";" on Windows).
    extra_roots = _os.environ.get("MEDIA_ALLOWED_ROOTS", "").strip()
    if extra_roots:
        for root in extra_roots.split(_os.pathsep):
            root = root.strip()
            if root:
                try:
                    rp = Path(root).resolve()
                    if rp.is_dir():
                        allowed_roots.append(rp)
                except Exception:
                    pass

    within_allowed = any(
        _os.path.commonpath([str(target), str(root)]) == str(root)
        for root in allowed_roots
        if root.exists()
    )
    if not within_allowed:
        return bad(handler, "Path not in allowed location", 403)

    if not target.exists() or not target.is_file():
        return j(handler, {"error": "not found"}, status=404)

    # Determine MIME type
    ext = target.suffix.lower()
    mime = MIME_MAP.get(ext, "application/octet-stream")

    # Only serve safe media/PDF types inline when explicitly requested. HTML is
    # allowed inline only with a CSP sandbox so "open full page" can work without
    # granting same-origin access to the WebUI. SVG is always a download (XSS risk).
    _INLINE_IMAGE_TYPES = {
        "image/png", "image/jpeg", "image/gif", "image/webp",
        "image/x-icon", "image/bmp",
    }
    _INLINE_PREVIEW_TYPES = _INLINE_IMAGE_TYPES | {
        "audio/mpeg", "audio/wav", "audio/x-wav", "audio/mp4", "audio/aac",
        "audio/ogg", "audio/opus", "audio/flac",
        "video/mp4", "video/quicktime", "video/webm", "video/ogg",
        "application/pdf",
    }
    _DOWNLOAD_TYPES = {"image/svg+xml"}  # SVG: XSS risk, force download
    inline_preview = qs.get("inline", [""])[0] == "1"
    html_inline_ok = inline_preview and mime == "text/html"
    disposition = "inline" if (
        mime not in _DOWNLOAD_TYPES and (
            mime in _INLINE_IMAGE_TYPES or (inline_preview and mime in _INLINE_PREVIEW_TYPES)
            or html_inline_ok
        )
    ) else "attachment"
    # serve_file_bytes sends Content-Security-Policy when csp is set.
    csp = "sandbox allow-scripts" if html_inline_ok else None
    return serve_file_bytes(handler, target, mime, disposition, "private, max-age=3600", csp=csp)


def _file_raw_target(session, sid: str, rel: str) -> Path | None:
    """Resolve /api/file/raw paths from the workspace or this session's uploads."""
    try:
        target = safe_resolve(Path(session.workspace), rel)
    except ValueError:
        target = None
    if target and target.exists() and target.is_file():
        return target

    # Chat uploads now live in a per-session attachment inbox outside the
    # workspace. Keep the public URL stable while scoping fallback lookup to
    # the requesting session's own attachment directory.
    try:
        from api.upload import _session_attachment_dir

        attachment_target = safe_resolve(_session_attachment_dir(sid), rel)
    except Exception:
        return None
    if attachment_target.exists() and attachment_target.is_file():
        return attachment_target
    return None


@answers_http_errors
def _handle_file_raw(handler, parsed):
    qs = parse_qs(parsed.query)
    sid = qs.get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id is required")
    s = session_or_404(sid)
    rel = qs.get("path", [""])[0]
    force_download = qs.get("download", [""])[0] == "1"
    target = _file_raw_target(s, sid, rel)
    if target is None:
        return j(handler, {"error": "not found"}, status=404)
    ext = target.suffix.lower()
    mime = MIME_MAP.get(ext, "application/octet-stream")
    # Security: force download for dangerous MIME types to prevent XSS.
    # Exception: ?inline=1 permits text/html to be served inline for the
    # sandboxed workspace HTML preview iframe (sandbox="allow-scripts" with no
    # allow-same-origin, so the iframe cannot access parent cookies/storage).
    inline_preview = qs.get("inline", [""])[0] == "1"
    dangerous_types = {"text/html", "application/xhtml+xml", "image/svg+xml"}
    html_inline_ok = inline_preview and mime == "text/html"
    disposition = "attachment" if force_download or (mime in dangerous_types and not html_inline_ok) else "inline"
    # Defense-in-depth for ?inline=1 HTML: even though the workspace.js iframe
    # sets sandbox="allow-scripts", a user could be tricked into opening the
    # ?inline=1 URL directly in a top-level tab (e.g. via a chat link), which
    # would render the HTML in the WebUI's origin without iframe sandbox. The
    # CSP sandbox directive applies the same isolation server-side: without
    # allow-same-origin, the document is treated as a unique opaque origin and
    # cannot read WebUI cookies, localStorage, or postMessage to the parent.
    csp = "sandbox allow-scripts" if html_inline_ok else None
    # serve_file_bytes sends Content-Security-Policy when csp is set.
    return serve_file_bytes(handler, target, mime, disposition, "no-store", csp=csp)


@answers_http_errors
def _handle_file_read(handler, parsed):
    qs = parse_qs(parsed.query)
    sid = qs.get("session_id", [""])[0]
    if not sid:
        return bad(handler, "session_id is required")
    s = session_or_404(sid)
    rel = qs.get("path", [""])[0]
    if not rel:
        return bad(handler, "path is required")
    try:
        return j(handler, read_file_content(Path(s.workspace), rel))
    except (FileNotFoundError, ValueError) as e:
        return bad(handler, _sanitize_error(e), 404)


def _build_tools_catalog():
    """Serialize the agent's tool registry for the mobile on-device-AI client.

    Returns ``{"tools": [{"name", "description", "toolset", "schema"}, ...]}``
    for every registered tool, sorted by name. Read-only and secret-free: it
    never exposes handlers, check_fns, or any callable — only the public
    metadata the local model needs to know the full server tool surface.

    Defensive by design: if the registry import fails (e.g. the agent isn't on
    the path in some deploy), it returns an empty list rather than 500ing.
    """
    try:
        from tools.registry import registry  # type: ignore
    except Exception:
        return {"tools": []}
    tools = []
    try:
        for name in registry.get_all_tool_names():
            entry = registry.get_entry(name)
            if entry is None:
                continue
            schema = entry.schema if isinstance(entry.schema, dict) else {}
            tools.append({
                "name": entry.name,
                "description": entry.description or schema.get("description", "") or "",
                "toolset": entry.toolset,
                "schema": schema,
            })
    except Exception:
        return {"tools": []}
    tools.sort(key=lambda t: t["name"])
    return {"tools": tools}


def _handle_live_models(handler, parsed):
    """Return the live model list for a provider.

    Delegates to the agent's provider_model_ids() which handles:
    - OpenRouter: live fetch from /api/v1/models
    - Anthropic: live fetch from /v1/models (API key or OAuth token)
    - Copilot: live fetch from api.githubcopilot.com/models with correct headers
    - openai-codex: Codex OAuth endpoint + local ~/.codex/ cache fallback
    - Nous: live fetch from inference-api.nousresearch.com/v1/models
    - DeepSeek, kimi-coding, opencode-zen/go, custom: generic OpenAI-compat /v1/models
    - ZAI, MiniMax, Google/Gemini: fall back to static list (non-standard endpoints)
    - All others: static _PROVIDER_MODELS fallback

    The agent already maintains all provider-specific auth and endpoint logic
    in one place; the WebUI inherits it rather than duplicating it.

    Query params:
        provider  (optional) — provider ID; defaults to active profile provider
    """
    qs = parse_qs(parsed.query)
    provider = (qs.get("provider", [""])[0] or "").lower().strip()

    try:
        from api.config import get_config as _gc
        cfg = _gc()
        if not provider:
            provider = cfg.get("model", {}).get("provider") or ""
        if not provider:
            return j(handler, {"error": "no_provider", "models": []})

        # Normalize provider alias so 'z.ai' -> 'zai', 'x.ai' -> 'xai', etc.
        # The browser sends whatever active_provider the static endpoint returned;
        # without normalization, provider_model_ids() misses the alias and returns [].
        # Uses the WebUI-owned table (api/config._resolve_provider_alias) which
        # works even when jarviscopilot_cli is not on sys.path.
        from api.config import _resolve_provider_alias
        provider = _resolve_provider_alias(provider)

        cache_key = _live_models_cache_key(provider)
        cached = _get_cached_live_models(cache_key)
        if cached is not None:
            return j(handler, cached)

        def _finish(payload: dict):
            _set_cached_live_models(cache_key, payload)
            return j(handler, payload)

        # Delegate to the agent's live-fetch + fallback resolver.
        # provider_model_ids() tries live endpoints first and falls back to
        # the static _PROVIDER_MODELS list — it never raises.
        try:
            import sys as _sys
            import os as _os
            _agent_dir = _os.path.join(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))),
                                       "..", "..", ".jarviscopilot", "jarviscopilot")
            _agent_dir = _os.path.normpath(_agent_dir)
            if _agent_dir not in _sys.path:
                _sys.path.insert(0, _agent_dir)
            from jarviscopilot_cli.models import provider_model_ids as _pmi
            ids = _pmi(provider)
        except Exception as _import_err:
            logger.debug("provider_model_ids import failed for %s: %s", provider, _import_err)
            ids = []

        if not ids:
            custom_provider_entry = None

            def _custom_provider_entries_for_request():
                if not (provider == "custom" or provider.startswith("custom:")):
                    return []
                try:
                    from api.config import _custom_provider_slug_from_name
                    _cp_entries = cfg.get("custom_providers", [])
                    if not isinstance(_cp_entries, list):
                        return []
                    _matches = []
                    for _cp in _cp_entries:
                        if not isinstance(_cp, dict):
                            continue
                        _slug = _custom_provider_slug_from_name(_cp.get("name", ""))
                        if provider.startswith("custom:"):
                            if _slug == provider:
                                _matches.append(_cp)
                        elif provider == "custom" and not _slug:
                            _matches.append(_cp)
                    return _matches
                except Exception:
                    return []

            def _custom_provider_model_ids(_cp):
                _ids = []

                def _append(_mid):
                    _mid = str(_mid or "").strip()
                    if _mid and _mid not in _ids:
                        _ids.append(_mid)

                _append(_cp.get("model", ""))
                _models = _cp.get("models")
                if isinstance(_models, dict):
                    for _mid in _models:
                        if isinstance(_mid, str):
                            _append(_mid)
                elif isinstance(_models, list):
                    for _item in _models:
                        if isinstance(_item, str):
                            _append(_item)
                        elif isinstance(_item, dict):
                            _append(_item.get("id") or _item.get("model") or _item.get("name"))
                return _ids

            def _custom_provider_api_key(_cp):
                _raw = _cp.get("api_key")
                if _raw is not None:
                    _key = str(_raw).strip()
                    if _key.startswith("${") and _key.endswith("}") and len(_key) > 3:
                        _key = os.getenv(_key[2:-1], "").strip()
                    if _key:
                        return _key
                _env = str(_cp.get("key_env") or "").strip()
                return os.getenv(_env, "").strip() if _env else ""

            # For 'custom' and 'custom:*' providers, provider_model_ids()
            # returns [] because they aren't real jarviscopilot_cli endpoints.
            # Fall back to the custom_providers entries from config.yaml so
            # the live-model enrichment step can add any models that weren't
            # already in the static list (issue #1619).
            if provider == "custom" or provider.startswith("custom:"):
                for _cp in _custom_provider_entries_for_request():
                    if custom_provider_entry is None:
                        custom_provider_entry = _cp
                    ids.extend(_custom_provider_model_ids(_cp))
            
            # If still no ids, try fetching from base_url directly (OpenAI-compat endpoint)
            if not ids and (provider == "custom" or provider.startswith("custom:")):
                _base_url = None
                _api_key = None
                if custom_provider_entry:
                    _base_url = custom_provider_entry.get("base_url")
                    _api_key = _custom_provider_api_key(custom_provider_entry)
                else:
                    _model_cfg = cfg.get("model", {})
                    _base_url = _model_cfg.get("base_url")
                    _api_key = _model_cfg.get("api_key")
                if _base_url and _api_key:
                    try:
                        import urllib.request
                        import json
                        
                        # Build the models endpoint URL
                        # AxonHub and similar OpenAI-compat endpoints serve /v1/models
                        _ep = _base_url.rstrip("/")
                        # If base_url already ends with /v1, use /models; otherwise add /v1/models
                        if _ep.endswith("/v1"):
                            _models_url = f"{_ep}/models"
                        else:
                            _models_url = f"{_ep}/v1/models"
                        
                        _req = urllib.request.Request(
                            _models_url,
                            headers={"Authorization": f"Bearer {_api_key}"},
                        )
                        
                        with urllib.request.urlopen(_req, timeout=8) as _resp:
                            _body = json.loads(_resp.read())
                        
                        # Parse response: {"data": [{"id": "model1", ...}, ...]}
                        if isinstance(_body, dict):
                            _data = _body.get("data", [])
                            if isinstance(_data, list):
                                ids = [m.get("id", "") for m in _data if m.get("id")]
                        elif isinstance(_body, list):
                            ids = [m.get("id", m) if isinstance(m, dict) else m for m in _body]
                        
                        if ids:
                            logger.debug("Live-fetched %d models from custom provider %s", len(ids), _base_url)
                        else:
                            logger.debug("Custom provider returned no models from %s", _base_url)
                    
                    except Exception as _fetch_err:
                        logger.debug("Live fetch from custom provider failed: %s", _fetch_err)

        # ── OpenAI-compat live fetch fallback ──────────────────────────────────
        # When provider_model_ids() is unavailable or returns [] for a provider
        # that exposes a standard /v1/models endpoint, fetch directly.  This
        # eliminates the need to keep _PROVIDER_MODELS in sync for providers
        # that have a discoverable API (#871).
        #
        # WARNING: This uses synchronous urllib.request which blocks the worker
        # thread for up to 8 seconds on timeout. This is acceptable because:
        #  (a) the server uses threading (not async), so other requests continue;
        #  (b) the frontend shows the static list immediately and enriches in
        #      the background via _fetchLiveModels(), so the user never waits.
        if not ids:
            _ep = _OPENAI_COMPAT_ENDPOINTS.get(provider)
            if _ep:
                try:
                    import urllib.request
                    _providers_cfg = cfg.get("providers", {})
                    _prov = _providers_cfg.get(provider, {}) if isinstance(_providers_cfg, dict) else {}
                    # Only use provider-scoped key — never fall back to a top-level
                    # api_key which may belong to a different provider.
                    _key = _prov.get("api_key") if isinstance(_prov, dict) else None
                    if not _key:
                        _key = cfg.get("model", {}).get("api_key")
                    if _key:
                        _req = urllib.request.Request(
                            f"{_ep}/models",
                            headers={"Authorization": f"Bearer {_key}"},
                        )
                        with urllib.request.urlopen(_req, timeout=8) as _resp:
                            _body = json.loads(_resp.read())
                        ids = [m.get("id", "") for m in _body.get("data", []) if m.get("id")]
                        logger.debug("Live-fetched %d models from %s /v1/models", len(ids), provider)
                except Exception as _fetch_err:
                    logger.debug("Live fetch from %s failed: %s", provider, _fetch_err)
                    # Fall through to static list below

        # Static fallback — only reached when live fetch also failed.
        if not ids:
            from api.config import _PROVIDER_MODELS as _pm
            ids = [m["id"] for m in _pm.get(provider, [])]
        if not ids:
            return _finish({"provider": provider, "models": [], "count": 0})

        # For Nous Portal, apply the same featured-set cap that
        # /api/models uses so background enrichment via _fetchLiveModels()
        # doesn't undo the dropdown trim — otherwise a 397-model catalog
        # would still flood the picker after the initial render finished
        # the cap. The full list is returned via the main /api/models
        # endpoint's extra_models field for /model autocomplete; the live
        # endpoint is purely a dropdown-enrichment surface, so it should
        # match the dropdown's visibility budget. (#1567)
        if provider == "nous":
            try:
                from api.config import _build_nous_featured_set
                _default_model = (cfg.get("model", {}) or {}).get("model") if isinstance(cfg.get("model"), dict) else None
                _featured, _ = _build_nous_featured_set(ids, selected_model_id=_default_model)
                ids = _featured
            except Exception:
                logger.debug("Failed to apply Nous featured-set cap for /api/models/live")

        # Normalise to {id, label} — provider_model_ids() returns plain string IDs.
        # For ollama-cloud use the shared Ollama formatter (handles `:variant` suffix).
        # For all other providers use a simpler hyphen-split capitaliser.
        from api.config import _format_ollama_label as _fmt_ollama

        def _make_label(mid):
            """Best-effort human label from a model ID string."""
            if provider in ("ollama", "ollama-cloud"):
                return _fmt_ollama(mid)
            # Preserve slashes for router IDs like "anthropic/claude-sonnet-4.6"
            display = mid.split("/")[-1] if "/" in mid else mid
            parts = display.split("-")
            result = []
            for p in parts:
                pl = p.lower()
                if pl == "gpt":
                    result.append("GPT")
                elif pl in ("claude", "gemini", "gemma", "llama", "mistral",
                            "qwen", "deepseek", "grok", "kimi", "glm"):
                    result.append(p.capitalize())
                elif p[:1].isdigit():
                    result.append(p)  # version numbers: 5.4, 3.5, 4.6 — unchanged
                else:
                    result.append(p.capitalize())
            label = " ".join(result)
            # Restore well-known uppercase tokens that title-casing breaks
            for orig in ("GPT", "GLM", "API", "AI", "XL", "MoE"):
                label = label.replace(orig.title(), orig)
            return label

        models_out = [{"id": mid, "label": _make_label(mid)} for mid in ids if mid]
        return _finish({"provider": provider, "models": models_out,
                        "count": len(models_out)})

    except Exception as _e:
        logger.debug("_handle_live_models failed for %s: %s", provider, _e)
        return j(handler, {"error": str(_e), "models": []})


def _handle_cron_history(handler, parsed):
    """List cron run output files with metadata (no content).

    Returns lightweight file listing so the frontend can render a run history
    without fetching full output for every run.
    """
    from cron.jobs import OUTPUT_DIR as CRON_OUT
    import re as _re

    qs = parse_qs(parsed.query)
    job_id = qs.get("job_id", [""])[0]
    if not job_id:
        return j(handler, {"error": "job_id required"}, status=400)
    # Defense-in-depth: cron job_ids are 12-char hex from the agent's scheduler.
    # Without validation, a job_id of "../<other>" would let an authenticated
    # caller enumerate .md filenames in adjacent directories under CRON_OUT's
    # parent. Mirror the rollback checkpoint id regex shape.
    # (Opus pre-release advisor finding.)
    if not _re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}", job_id) or job_id in (".", ".."):
        return j(handler, {"error": "invalid job_id"}, status=400)
    # Reject malformed offset/limit instead of letting int() raise ValueError
    # and surface as a confusing 500. Clamp to safe ranges.
    try:
        offset = max(0, int(qs.get("offset", ["0"])[0]))
        limit = max(1, min(500, int(qs.get("limit", ["50"])[0])))
    except (ValueError, TypeError):
        return j(handler, {"error": "offset and limit must be integers"}, status=400)
    out_dir = CRON_OUT / job_id
    runs = []
    total = 0
    if out_dir.exists():
        all_files = sorted(out_dir.glob("*.md"), key=lambda f: f.stat().st_mtime, reverse=True)
        total = len(all_files)
        page = all_files[offset:offset + limit]
        for f in page:
            try:
                st = f.stat()
                usage = _cron_output_usage_metadata(
                    f.read_text(encoding="utf-8", errors="replace")
                )
                runs.append({
                    "filename": f.name,
                    "size": st.st_size,
                    "modified": st.st_mtime,
                    "usage": usage,
                })
            except OSError:
                logger.debug("Failed to stat cron output file %s", f)
    return j(handler, {"job_id": job_id, "runs": runs, "total": total, "offset": offset})


def _handle_cron_run_detail(handler, parsed):
    """Return full content of a single cron run output file."""
    from cron.jobs import OUTPUT_DIR as CRON_OUT
    import re as _re

    qs = parse_qs(parsed.query)
    job_id = qs.get("job_id", [""])[0]
    filename = qs.get("filename", [""])[0]
    if not job_id or not filename:
        return j(handler, {"error": "job_id and filename required"}, status=400)
    # Validate job_id shape (defense-in-depth even though the resolve+is_relative_to
    # check below catches traversal — fail-closed at the parameter boundary so
    # malformed job_ids return a 400 from the validator rather than a 400 from
    # the path resolver).
    if not _re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}", job_id) or job_id in (".", ".."):
        return j(handler, {"error": "invalid job_id"}, status=400)
    # Prevent path traversal — resolve and verify it stays within the job's output dir
    fpath = (CRON_OUT / job_id / filename).resolve()
    if not fpath.is_relative_to(CRON_OUT.resolve()):
        return j(handler, {"error": "invalid filename"}, status=400)
    if not fpath.exists():
        return j(handler, {"error": "run not found"}, status=404)
    try:
        content = fpath.read_text(encoding="utf-8", errors="replace")
        snippet = _cron_output_snippet(content)
        usage = _cron_output_usage_metadata(content)
        return j(handler, {"job_id": job_id, "filename": filename,
                           "content": content, "snippet": snippet,
                           "usage": usage})
    except Exception as e:
        return j(handler, {"error": str(e)}, status=500)


def _cron_output_usage_metadata(text: str) -> dict:
    """Extract optional token/cost metadata from a cron output markdown file."""
    import re as _re

    head = text.split("## Response", 1)[0].split("# Response", 1)[0]
    usage: dict = {}

    def _intish(value: str):
        cleaned = _re.sub(r"[^0-9]", "", value or "")
        return int(cleaned) if cleaned else None

    def _floatish(value: str):
        match = _re.search(r"[-+]?\d+(?:\.\d+)?", (value or "").replace(",", ""))
        return float(match.group(0)) if match else None

    for raw_line in head.splitlines():
        line = raw_line.strip()
        model_match = _re.match(r"\*\*(?:Model|Model Used):\*\*\s*(.+)$", line, _re.I)
        if model_match:
            usage["model"] = model_match.group(1).strip()
            continue
        provider_match = _re.match(r"\*\*Provider:\*\*\s*(.+)$", line, _re.I)
        if provider_match:
            usage["provider"] = provider_match.group(1).strip()
            continue
        cost_match = _re.match(r"\*\*(?:Estimated cost|Cost):\*\*\s*(.+)$", line, _re.I)
        if cost_match:
            cost = _floatish(cost_match.group(1))
            if cost is not None:
                usage["estimated_cost_usd"] = cost
            continue
        duration_match = _re.match(r"\*\*(?:Duration|Elapsed):\*\*\s*(.+)$", line, _re.I)
        if duration_match:
            seconds = _floatish(duration_match.group(1))
            if seconds is not None:
                usage["duration_seconds"] = seconds
            continue
        tokens_match = _re.match(r"\*\*Tokens:\*\*\s*(.+)$", line, _re.I)
        if tokens_match:
            value = tokens_match.group(1)
            input_match = _re.search(r"([0-9][0-9,]*)\s*(?:input|in)\b", value, _re.I)
            output_match = _re.search(r"([0-9][0-9,]*)\s*(?:output|out)\b", value, _re.I)
            total_match = _re.search(r"([0-9][0-9,]*)\s*(?:total\s*)?tokens?\b", value, _re.I)
            if input_match:
                usage["input_tokens"] = _intish(input_match.group(1))
            if output_match:
                usage["output_tokens"] = _intish(output_match.group(1))
            if total_match and "total_tokens" not in usage:
                usage["total_tokens"] = _intish(total_match.group(1))

    if "total_tokens" not in usage:
        total = sum(int(usage.get(k) or 0) for k in ("input_tokens", "output_tokens"))
        if total:
            usage["total_tokens"] = total
    return usage


def _cron_output_snippet(text: str, limit: int = 600) -> str:
    """Extract the response body from a cron output .md file for preview.

    Contract: cron output files use markdown front-matter followed by a
    ``## Response`` (or ``# Response``) heading that marks the start of the
    agent's reply.  This function locates that heading and returns everything
    after it (up to *limit* chars).  If no heading is found the entire text
    is returned — callers should be aware that front-matter fields (model,
    timestamp, …) may appear in the snippet.
    """
    lines = text.split("\n")
    response_idx = -1
    for i, line in enumerate(lines):
        if line.startswith("## Response") or line.startswith("# Response"):
            response_idx = i
            break
    body = ("\n".join(lines[response_idx + 1:]) if response_idx >= 0 else "\n".join(lines)).strip()
    return body[:limit] or "(empty)"


def _handle_cron_output(handler, parsed):
    from cron.jobs import OUTPUT_DIR as CRON_OUT

    qs = parse_qs(parsed.query)
    job_id = qs.get("job_id", [""])[0]
    limit = int(qs.get("limit", ["5"])[0])
    if not job_id:
        return j(handler, {"error": "job_id required"}, status=400)
    out_dir = CRON_OUT / job_id
    outputs = []
    if out_dir.exists():
        files = sorted(out_dir.glob("*.md"), key=lambda f: f.stat().st_mtime, reverse=True)[:limit]
        for f in files:
            try:
                txt = f.read_text(encoding="utf-8", errors="replace")
                outputs.append({"filename": f.name, "content": _cron_output_content_window(txt)})
            except Exception:
                logger.debug("Failed to read cron output file %s", f)
    return j(handler, {"job_id": job_id, "outputs": outputs})


def _handle_cron_status(handler, parsed):
    """Return running status for one or all cron jobs."""
    qs = parse_qs(parsed.query)
    job_id = qs.get("job_id", [""])[0]
    if job_id:
        running, elapsed = _is_cron_running(job_id)
        return j(handler, {"job_id": job_id, "running": running, "elapsed": round(elapsed, 1)})
    # Return status for all running jobs
    with _RUNNING_CRON_LOCK:
        all_running = {jid: round(time.time() - t, 1) for jid, t in _RUNNING_CRON_JOBS.items()}
    return j(handler, {"running": all_running})


def _handle_cron_recent(handler, parsed):
    """Return cron jobs that have completed since a given timestamp."""
    import datetime

    qs = parse_qs(parsed.query)
    since = float(qs.get("since", ["0"])[0])
    try:
        from cron.jobs import list_jobs

        jobs = list_jobs(include_disabled=True)
        completions = []
        for job in jobs:
            last_run = job.get("last_run_at")
            if not last_run:
                continue
            if isinstance(last_run, str):
                try:
                    ts = datetime.datetime.fromisoformat(
                        last_run.replace("Z", "+00:00")
                    ).timestamp()
                except (ValueError, TypeError):
                    continue
            else:
                ts = float(last_run)
            if ts > since:
                completions.append(
                    {
                        "job_id": job.get("id", ""),
                        "name": job.get("name", "Unknown"),
                        "status": job.get("last_status", "unknown"),
                        "completed_at": ts,
                        "toast_notifications": job.get("toast_notifications") is not False,
                    }
                )
        return j(handler, {"completions": completions, "since": since})
    except ImportError:
        return j(handler, {"completions": [], "since": since})


def _handle_memory_read(handler):
    try:
        from api.profiles import get_active_hermes_home

        mem_dir = get_active_hermes_home() / "memories"
    except ImportError:
        mem_dir = Path.home() / ".jarviscopilot" / "memories"
    mem_file = mem_dir / "MEMORY.md"
    user_file = mem_dir / "USER.md"
    memory = (
        mem_file.read_text(encoding="utf-8", errors="replace")
        if mem_file.exists()
        else ""
    )
    user = (
        user_file.read_text(encoding="utf-8", errors="replace")
        if user_file.exists()
        else ""
    )
    return j(
        handler,
        {
            "memory": _redact_text(memory),
            "user": _redact_text(user),
            "memory_path": str(mem_file),
            "user_path": str(user_file),
            "memory_mtime": mem_file.stat().st_mtime if mem_file.exists() else None,
            "user_mtime": user_file.stat().st_mtime if user_file.exists() else None,
        },
    )


# ── POST route helpers ────────────────────────────────────────────────────────


@answers_http_errors
def _handle_btw(handler, body):
    """POST /api/btw — ephemeral side question using session context.

    Creates a temporary hidden session, streams the answer via SSE, then
    discards the session. The parent session is not modified.
    """
    try:
        require(body, "session_id")
        require(body, "question")
    except ValueError as e:
        return bad(handler, str(e))
    s = session_or_404(body["session_id"])
    question = str(body["question"]).strip()
    if not question:
        return bad(handler, "question is required")
    # Duplicate-stream guard (same pattern as chat/start)
    current_stream_id = getattr(s, "active_stream_id", None)
    if current_stream_id:
        with STREAMS_LOCK:
            if current_stream_id in STREAMS:
                return j(handler, {"error": "session already has an active stream"}, status=409)
        s.active_stream_id = None
    # Create ephemeral hidden session inheriting context
    from api.models import new_session as _new_session
    model_provider = getattr(s, 'model_provider', None)
    ephemeral = _new_session(
        workspace=s.workspace,
        model=s.model,
        model_provider=model_provider,
        profile=getattr(s, 'profile', None),
    )
    # Copy conversation history for context (agent reads from messages)
    ephemeral.messages = list(s.messages or [])
    ephemeral.title = f"btw: {question[:60]}"
    ephemeral.save()
    stream_id = uuid.uuid4().hex
    ephemeral.active_stream_id = stream_id
    ephemeral.save()
    stream = create_stream_channel()
    with STREAMS_LOCK:
        STREAMS[stream_id] = stream
    from api.background import track_btw
    track_btw(body["session_id"], ephemeral.session_id, stream_id, question)
    thr = threading.Thread(
        target=_run_agent_streaming,
        args=(ephemeral.session_id, question, s.model, s.workspace, stream_id, None),
        kwargs={"ephemeral": True, "model_provider": model_provider},
        daemon=True,
    )
    thr.start()
    return j(handler, {"stream_id": stream_id, "session_id": ephemeral.session_id, "parent_session_id": body["session_id"]})


@answers_http_errors
def _handle_background(handler, body):
    """POST /api/background — run prompt in parallel background agent.

    Creates a hidden session, starts streaming in a daemon thread.
    Frontend polls /api/background/status for completed results.
    """
    try:
        require(body, "session_id")
        require(body, "prompt")
    except ValueError as e:
        return bad(handler, str(e))
    s = session_or_404(body["session_id"])
    prompt = str(body["prompt"]).strip()
    if not prompt:
        return bad(handler, "prompt is required")
    from api.models import new_session as _new_session
    model_provider = getattr(s, 'model_provider', None)
    bg = _new_session(
        workspace=s.workspace,
        model=s.model,
        model_provider=model_provider,
        profile=getattr(s, 'profile', None),
    )
    bg.title = f"bg: {prompt[:60]}"
    bg.save()
    stream_id = uuid.uuid4().hex
    bg.active_stream_id = stream_id
    bg.save()
    stream = create_stream_channel()
    with STREAMS_LOCK:
        STREAMS[stream_id] = stream
    task_id = uuid.uuid4().hex[:8]
    from api.background import track_background, complete_background
    parent_sid = body["session_id"]
    bg_sid = bg.session_id
    track_background(parent_sid, bg_sid, stream_id, task_id, prompt)

    def _run_bg_and_notify():
        """Run the background agent, then mark the tracked task `done` with the
        last assistant reply so `/api/background/status` can surface it.  Without
        this, `complete_background()` is never called and the result is lost —
        `get_results()` would see a forever-`running` task and return nothing.
        """
        try:
            _run_agent_streaming(
                bg_sid,
                prompt,
                s.model,
                s.workspace,
                stream_id,
                None,
                model_provider=model_provider,
            )
            # Reload the bg session from disk and extract the final assistant reply.
            try:
                from api.models import Session as _Session
                reloaded = _Session.load(bg_sid)
                _answer = ""
                for _m in reversed((reloaded.messages if reloaded else None) or []):
                    if not isinstance(_m, dict) or _m.get("role") != "assistant":
                        continue
                    if _m.get("_error"):
                        continue
                    _content = str(_m.get("content") or "").strip()
                    if _content:
                        _answer = _content
                        break
                complete_background(parent_sid, task_id, _answer or "(no answer produced)")
            except Exception:
                complete_background(parent_sid, task_id, "(background task failed)")
            # Best-effort cleanup of the hidden bg session file so it doesn't
            # clutter the sidebar or SESSION_DIR. The index is pruned on the
            # next rebuild via _index_entry_exists().
            try:
                (SESSION_DIR / f"{bg_sid}.json").unlink(missing_ok=True)
            except Exception:
                pass
        except Exception:
            try:
                complete_background(parent_sid, task_id, "(background task failed)")
            except Exception:
                pass

    thr = threading.Thread(target=_run_bg_and_notify, daemon=True)
    thr.start()
    return j(handler, {"task_id": task_id, "stream_id": stream_id, "session_id": bg.session_id})


@answers_http_errors
def _handle_goal_command(handler, body):
    """Handle WebUI /goal command controls and optional kickoff stream."""
    need(body, "session_id")
    s = session_or_404(body["session_id"])

    requested_profile = str(body.get("profile") or "").strip()
    if requested_profile:
        try:
            from api.profiles import _PROFILE_ID_RE

            if requested_profile != "default" and not _PROFILE_ID_RE.fullmatch(requested_profile):
                return bad(handler, "invalid profile", 400)
        except ImportError:
            requested_profile = ""
    if requested_profile and not _profiles_match(getattr(s, "profile", None), requested_profile):
        has_persisted_turns = bool(
            getattr(s, "messages", None)
            or getattr(s, "context_messages", None)
            or getattr(s, "pending_user_message", None)
        )
        if not has_persisted_turns:
            s.profile = requested_profile

    current_stream_id = getattr(s, "active_stream_id", None)
    stream_running = False
    if current_stream_id:
        with STREAMS_LOCK:
            stream_running = current_stream_id in STREAMS
        if not stream_running:
            clear_stale_stream_state(s)

    try:
        from api.profiles import get_hermes_home_for_profile

        profile_home = get_hermes_home_for_profile(getattr(s, "profile", None))
    except Exception:
        profile_home = None

    from api.goals import goal_command_payload, goal_state_snapshot, restore_goal_state

    goal_args = str(body.get("args", "") or body.get("text", "") or "")
    goal_action = goal_args.strip().lower()
    will_kickoff = bool(
        goal_args.strip()
        and goal_action not in ("status", "pause", "resume", "clear", "stop", "done")
        and not stream_running
    )
    workspace = model = model_provider = normalized_model = None
    previous_goal_state = None
    if will_kickoff:
        try:
            workspace = str(resolve_trusted_workspace(body.get("workspace") or s.workspace))
        except ValueError as e:
            return bad(handler, str(e))
        requested_model = body.get("model") or s.model
        requested_provider = (
            body.get("model_provider")
            if "model_provider" in body
            else getattr(s, "model_provider", None)
        )
        model, model_provider, normalized_model = resolve_session_model_state(
            requested_model,
            requested_provider,
        )
        previous_goal_state = goal_state_snapshot(s.session_id, profile_home=profile_home)

    payload = goal_command_payload(
        s.session_id,
        goal_args,
        stream_running=stream_running,
        profile_home=profile_home,
    )
    if not payload.get("ok", True):
        status = 409 if payload.get("error") == "agent_running" else 400
        return j(handler, payload, status=status)

    kickoff_prompt = str(payload.get("kickoff_prompt") or "").strip()
    if kickoff_prompt:
        if workspace is None:
            try:
                workspace = str(resolve_trusted_workspace(body.get("workspace") or s.workspace))
            except ValueError as e:
                return bad(handler, str(e))
        if model is None:
            requested_model = body.get("model") or s.model
            requested_provider = (
                body.get("model_provider")
                if "model_provider" in body
                else getattr(s, "model_provider", None)
            )
            model, model_provider, normalized_model = resolve_session_model_state(
                requested_model,
                requested_provider,
            )
        stream_response = start_turn(
            s,
            msg=kickoff_prompt,
            attachments=[],
            workspace=workspace,
            model=model,
            model_provider=model_provider,
            normalized_model=normalized_model,
            goal_related=True,
        )
        status = int(stream_response.pop("_status", 200) or 200)
        payload.update(stream_response)
        if status >= 400:
            restore_goal_state(s.session_id, previous_goal_state, profile_home=profile_home)
            payload["ok"] = False
            return j(handler, payload, status=status)

    return j(handler, payload)


@answers_http_errors
def _handle_chat_start(handler, body, diag=None, stream=False):
    """Handle POST /api/chat/start.

    ``stream=True`` (plan 5.1 — ``?stream=1`` or an SSE Accept header) keeps
    the same connection open and streams the turn's SSE events on it instead
    of returning a plain JSON body; the older two-step flow (JSON response,
    then a separate ``GET /api/stream``) is unchanged when ``stream=False``.
    """
    try:
        diag.stage("validate_session_id") if diag else None
        need(body, "session_id")
        diag.stage("get_session") if diag else None
        s = session_or_404(body["session_id"])
        diag.stage("validate_profile") if diag else None
        requested_profile = str(body.get("profile") or "").strip()
        if requested_profile:
            try:
                from api.profiles import _PROFILE_ID_RE

                if requested_profile != "default" and not _PROFILE_ID_RE.fullmatch(requested_profile):
                    return bad(handler, "invalid profile", 400)
            except ImportError:
                requested_profile = ""
        if requested_profile and not _profiles_match(getattr(s, "profile", None), requested_profile):
            has_persisted_turns = bool(
                getattr(s, "messages", None)
                or getattr(s, "context_messages", None)
                or getattr(s, "pending_user_message", None)
            )
            if not has_persisted_turns:
                # Empty sessions are placeholders. If the user switches profiles
                # before sending the first turn, run the placeholder under the
                # currently-selected profile instead of the stale one stamped at
                # creation time.
                s.profile = requested_profile
        diag.stage("normalize_message") if diag else None
        msg = str(body.get("message", "")).strip()
        if not msg:
            return bad(handler, "message is required")
        # Voice clients (e.g. the Apple Watch) relay straight to chat/start and
        # bypass the web voice path that prepends the spoken-reply directive.
        # Honor a `voice` flag here so they get the same terse, ack-only,
        # no-step-narration behavior as phone/web voice.
        if body.get("voice"):
            try:
                from api.voice import _VOICE_REPLY_DIRECTIVE
                if not msg.startswith("[Voice mode"):
                    msg = _VOICE_REPLY_DIRECTIVE + msg
            except Exception:
                pass
        diag.stage("normalize_attachments") if diag else None
        attachments = _normalize_chat_attachments(body.get("attachments") or [])[:20]
        diag.stage("resolve_workspace") if diag else None
        try:
            workspace = _resolve_chat_workspace_with_recovery(s, body.get("workspace"))
        except ValueError as e:
            return bad(handler, str(e))
        requested_model = body.get("model") or s.model
        requested_provider = (
            body.get("model_provider")
            if "model_provider" in body
            else getattr(s, "model_provider", None)
        )
        diag.stage("resolve_model_provider") if diag else None
        model, model_provider, normalized_model = resolve_session_model_state(
            requested_model,
            requested_provider,
        )
        from api.runtime_adapter import (
            LegacyJournalRuntimeAdapter,
            StartRunRequest,
            runtime_adapter_enabled,
        )

        # Which paired device sent this (api/turn_origin.py): a note to the model for
        # this call, and the default target for device tools.
        origin_note = ""
        try:
            from api import turn_origin
            _origin = turn_origin.origin_for_handler(handler)
            origin_note = turn_origin.directive(_origin, "chat") or ""
            turn_origin.note_turn(s.session_id, _origin)
        except Exception:
            logger.debug("chat start: sending device not noted", exc_info=True)

        turn = turn_options_for_chat(s, body, model, model_provider, context=origin_note)

        if runtime_adapter_enabled():
            def _legacy_start_run(request: StartRunRequest) -> dict:
                return start_turn(
                    s,
                    msg=request.message,
                    attachments=request.attachments,
                    workspace=request.workspace or workspace,
                    model=request.model or model,
                    model_provider=request.provider or model_provider,
                    normalized_model=normalized_model,
                    diag=diag,
                    turn=turn,
                )

            adapter = LegacyJournalRuntimeAdapter(start_run_delegate=_legacy_start_run)
            result = adapter.start_run(
                StartRunRequest(
                    session_id=s.session_id,
                    message=msg,
                    attachments=attachments,
                    workspace=workspace,
                    profile=getattr(s, "profile", None),
                    provider=model_provider,
                    model=model,
                    source="webui",
                    metadata={"route": "/api/chat/start"},
                )
            )
            response = dict(result.payload)
            response.setdefault("stream_id", result.stream_id)
            response.setdefault("session_id", result.session_id)
        else:
            response = start_turn(
                s,
                msg=msg,
                attachments=attachments,
                workspace=workspace,
                model=model,
                model_provider=model_provider,
                normalized_model=normalized_model,
                diag=diag,
                turn=turn,
            )
        status = int(response.pop("_status", 200) or 200)
        diag.stage("response_write") if diag else None
        if stream and status < 400 and response.get("stream_id"):
            return _stream_chat_start_response(handler, response)
        return j(handler, response, status=status)
    finally:
        if diag:
            diag.finish()


def _normalize_chat_attachments(raw_attachments):
    """Normalize attachment payloads from the browser.

    Older clients send a list of filenames. Newer clients send upload result
    objects containing name/path/mime/size so image attachments can be supplied
    to JarvisCopilot as native multimodal inputs for the current turn.
    """
    normalized = []
    if not isinstance(raw_attachments, list):
        return normalized
    for item in raw_attachments:
        if isinstance(item, dict):
            name = str(item.get("name") or item.get("filename") or "").strip()
            path = str(item.get("path") or "").strip()
            mime = str(item.get("mime") or "").strip()
            att = {"name": name or path, "path": path, "mime": mime}
            size = item.get("size")
            if isinstance(size, int):
                att["size"] = size
            is_image = item.get("is_image")
            if isinstance(is_image, bool):
                att["is_image"] = is_image
            normalized.append(att)
        else:
            value = str(item).strip()
            if value:
                normalized.append({"name": value, "path": "", "mime": ""})
    return normalized


def _handle_chat_sync(handler, body):
    """Fallback synchronous chat endpoint (POST /api/chat). Not used by frontend."""
    s = get_session(body["session_id"])
    msg = str(body.get("message", "")).strip()
    if not msg:
        return j(handler, {"error": "empty message"}, status=400)
    try:
        workspace = str(resolve_trusted_workspace(body.get("workspace") or s.workspace))
    except ValueError as e:
        return bad(handler, str(e))
    with _get_session_agent_lock(s.session_id):
        s.workspace = workspace
        model, model_provider = resolve_session_model_state(
            body.get("model") or s.model,
            body.get("model_provider") if "model_provider" in body else getattr(s, "model_provider", None),
        )[:2]
        s.model = model
        s.model_provider = model_provider
    from api.config import ENV_LOCK

    with ENV_LOCK:
        old_cwd = os.environ.get("TERMINAL_CWD")
        os.environ["TERMINAL_CWD"] = str(workspace)
        old_exec_ask = os.environ.get("HERMES_EXEC_ASK")
        old_session_key = os.environ.get("HERMES_SESSION_KEY")
        os.environ["HERMES_EXEC_ASK"] = "1"
        os.environ["HERMES_SESSION_KEY"] = s.session_id
    try:
        from run_agent import AIAgent

        with CHAT_LOCK:
            from api.config import resolve_model_provider, route_anthropic_via_claude_code

            _model, _provider, _base_url = route_anthropic_via_claude_code(*resolve_model_provider(
                model_with_provider_context(s.model, getattr(s, "model_provider", None))
            ))
            from api.oauth import runtime_credentials
            _api_key, _provider, _base_url = runtime_credentials(_provider, _base_url, what="a side chat")
            agent = AIAgent(
                model=_model,
                provider=_provider,
                base_url=_base_url,
                api_key=_api_key,
                # Identify browser-originated sessions as WebUI so JarvisCopilot
                # does not inject CLI-specific terminal/output guidance.
                platform="webui",
                quiet_mode=True,
                enabled_toolsets=_resolve_cli_toolsets(),
                session_id=s.session_id,
            )
            from api.streaming import (
                _merge_display_messages_after_agent_result,
                _restore_reasoning_metadata,
                _sanitize_messages_for_api,
                _context_messages_for_new_turn,
                _workspace_context_prefix,
            )
            workspace_ctx = _workspace_context_prefix(str(s.workspace))
            workspace_system_msg = (
                f"Active workspace at session start: {s.workspace}\n"
                "Every user message is prefixed with [Workspace::v1: /absolute/path] indicating the "
                "workspace the user has selected in the web UI at the time they sent that message. "
                "This tag is the single authoritative source of the active workspace and updates "
                "with every message. It overrides any prior workspace mentioned in this system "
                "prompt, memory, or conversation history. Always use the value from the most recent "
                "[Workspace::v1: ...] tag as your default working directory for ALL file operations: "
                "write_file, read_file, search_files, terminal workdir, and patch. "
                "Never fall back to a hardcoded path when this tag is present."
            )

            _previous_messages = list(s.messages or [])
            _previous_context_messages = list(_context_messages_for_new_turn(s, msg))

            result = agent.run_conversation(
                user_message=workspace_ctx + msg,
                system_message=workspace_system_msg,
                conversation_history=_sanitize_messages_for_api(_previous_context_messages, cfg=get_config()),
                task_id=s.session_id,
                persist_user_message=msg,
            )
    finally:
        with ENV_LOCK:
            if old_cwd is None:
                os.environ.pop("TERMINAL_CWD", None)
            else:
                os.environ["TERMINAL_CWD"] = old_cwd
            if old_exec_ask is None:
                os.environ.pop("HERMES_EXEC_ASK", None)
            else:
                os.environ["HERMES_EXEC_ASK"] = old_exec_ask
            if old_session_key is None:
                os.environ.pop("HERMES_SESSION_KEY", None)
            else:
                os.environ["HERMES_SESSION_KEY"] = old_session_key
    with _get_session_agent_lock(s.session_id):
        _result_messages = result.get("messages") or _previous_context_messages
        _next_context_messages = _restore_reasoning_metadata(
            _previous_context_messages,
            _result_messages,
        )
        s.context_messages = _next_context_messages
        s.messages = _merge_display_messages_after_agent_result(
            _previous_messages,
            _previous_context_messages,
            _next_context_messages,
            msg,
        )
        # Only auto-generate title when still default; preserves user renames
        if s.title == "Untitled":
            s.title = title_from(s.messages, s.title)
        s.save()
    # Sync to state.db for /insights (opt-in setting)
    try:
        if load_settings().get("sync_to_insights"):
            from api.state_sync import sync_session_usage

            sync_session_usage(
                session_id=s.session_id,
                input_tokens=s.input_tokens or 0,
                output_tokens=s.output_tokens or 0,
                estimated_cost=s.estimated_cost,
                model=s.model,
                title=s.title,
                message_count=len(s.messages),
            )
    except Exception:
        logger.debug("Failed to update session cost tracking")
    return j(
        handler,
        {
            "answer": result.get("final_response") or "",
            "status": "done" if result.get("completed", True) else "partial",
            "session": s.compact() | {"messages": s.messages},
            "result": {k: v for k, v in result.items() if k != "messages"},
        },
    )


@answers_http_errors
def _handle_cron_create(handler, body):
    need(body, "prompt", "schedule")
    try:
        from cron.jobs import create_job, update_job

        runs_on_fields = _cron_runs_on_fields(body)
        toast_notifications = body.get("toast_notifications") is not False
        job = create_job(
            prompt=body["prompt"],
            schedule=body["schedule"],
            name=body.get("name") or None,
            deliver=body.get("deliver") or "local",
            skills=body.get("skills") or [],
            model=runs_on_fields.get("model") or None,
            provider=runs_on_fields.get("provider") or None,
            harness_id=runs_on_fields.get("harness_id") or None,
            integration=_known_integration(body.get("integration")),
        )
        post_create_updates = {}
        if not toast_notifications:
            post_create_updates["toast_notifications"] = False
        if post_create_updates:
            job = update_job(job["id"], post_create_updates) or job
        return j(handler, {"ok": True, "job": _cron_job_for_api(job)})
    except Exception as e:
        return j(handler, {"error": str(e)}, status=400)


def _known_integration(value):
    """The integration id, if it names one that exists. Otherwise None (General).

    A job tagged with an id no space has matches no integration in `schedules_for`
    and is not General either, so it would keep firing while showing up nowhere.
    """
    space_id = str(value or "").strip().lower()
    if not space_id:
        return None
    try:
        from jarvis_registry.store import shared

        if shared().exists(space_id):
            return space_id
    except Exception:
        return None
    return None


@answers_http_errors
def _handle_cron_update(handler, body):
    need(body, "job_id")
    from cron.jobs import get_job, update_job

    try:
        updates = {}
        for k, v in body.items():
            # The per-job profile is gone; runs_on is derived, never stored.
            if k in ("job_id", "profile", "runs_on", "model", "provider", "harness_id"):
                continue
            if v is not None:
                updates[k] = v
        # Sent explicitly so an editor can clear them (Default clears all three).
        stored = get_job(body["job_id"]) or {}
        updates.update(_cron_runs_on_fields(body, current_harness_id=stored.get("harness_id")))
        job = update_job(body["job_id"], updates)
    except ValueError as e:
        return bad(handler, str(e))
    if not job:
        return bad(handler, "Job not found", 404)
    return j(handler, {"ok": True, "job": _cron_job_for_api(job)})


@answers_http_errors
def _handle_cron_delete(handler, body):
    need(body, "job_id")
    from cron.jobs import remove_job

    ok = remove_job(body["job_id"])
    if not ok:
        return bad(handler, "Job not found", 404)
    return j(handler, {"ok": True, "job_id": body["job_id"]})


def _handle_cron_run(handler, body):
    job_id = body.get("job_id", "")
    if not job_id:
        return bad(handler, "job_id required")
    from cron.jobs import get_job

    job = get_job(job_id)
    if not job:
        return bad(handler, "Job not found", 404)
    # Prevent double-run: reject if the job is already tracked as running
    already_running, elapsed = _is_cron_running(job_id)
    if already_running:
        return j(handler, {"ok": False, "job_id": job_id, "status": "already_running",
                            "elapsed": round(elapsed, 1)})
    _mark_cron_running(job_id)
    # Capture the TLS-active profile home now — the thread runs after the
    # request finishes, so TLS is gone by then.
    #
    # Resolve directly without a try/except: get_active_hermes_home() does
    # in-memory dict reads + a single Path.is_dir() stat, so the only way
    # it could raise from inside a request handler is if api.profiles
    # itself partially failed to import (in which case we'd already be
    # 500-ing the whole request). A silent fallback to None here would
    # re-introduce the exact bug #1573 fixes — the worker thread would
    # run unpinned against the process-global HERMES_HOME — so we'd
    # rather let any unexpected exception 500 the request than corrupt
    # cross-profile state.
    from api.profiles import get_active_hermes_home

    _profile_home = get_active_hermes_home()
    threading.Thread(target=_run_cron_tracked, args=(job, _profile_home), daemon=True).start()
    return j(handler, {"ok": True, "job_id": job_id, "status": "running"})


def _handle_cron_pause(handler, body):
    job_id = body.get("job_id", "")
    if not job_id:
        return bad(handler, "job_id required")
    from cron.jobs import pause_job

    result = pause_job(job_id, reason=body.get("reason"))
    if result:
        return j(handler, {"ok": True, "job": result})
    return bad(handler, "Job not found", 404)


def _handle_cron_resume(handler, body):
    job_id = body.get("job_id", "")
    if not job_id:
        return bad(handler, "job_id required")
    from cron.jobs import resume_job

    result = resume_job(job_id)
    if result:
        return j(handler, {"ok": True, "job": result})
    return bad(handler, "Job not found", 404)


@answers_http_errors
def _handle_file_delete(handler, body):
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        if not target.exists():
            return bad(handler, "File not found", 404)
        if target.is_dir():
            if not body.get("recursive"):
                return bad(handler, "Set recursive=true to delete directories")
            shutil.rmtree(target)
        else:
            target.unlink()
        return j(handler, {"ok": True, "path": body["path"]})
    except (ValueError, PermissionError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_file_save(handler, body):
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        if not target.exists():
            return bad(handler, "File not found", 404)
        if target.is_dir():
            return bad(handler, "Cannot save: path is a directory")
        target.write_text(body.get("content", ""), encoding="utf-8")
        return j(
            handler, {"ok": True, "path": body["path"], "size": target.stat().st_size}
        )
    except (ValueError, PermissionError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_file_create(handler, body):
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        if target.exists():
            return bad(handler, "File already exists")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body.get("content", ""), encoding="utf-8")
        return j(
            handler, {"ok": True, "path": str(target.relative_to(Path(s.workspace)))}
        )
    except (ValueError, PermissionError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_file_rename(handler, body):
    need(body, "session_id", "path", "new_name")
    s = session_or_404(body["session_id"])
    try:
        source = safe_resolve(Path(s.workspace), body["path"])
        if not source.exists():
            return bad(handler, "File not found", 404)
        new_name = body["new_name"].strip()
        if not new_name or "/" in new_name or ".." in new_name:
            return bad(handler, "Invalid file name")
        dest = source.parent / new_name
        if dest.exists():
            return bad(handler, f'A file named "{new_name}" already exists')
        source.rename(dest)
        new_rel = str(dest.relative_to(Path(s.workspace)))
        return j(handler, {"ok": True, "old_path": body["path"], "new_path": new_rel})
    except (ValueError, PermissionError, OSError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_create_dir(handler, body):
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        if target.exists():
            return bad(handler, "Path already exists")
        target.mkdir(parents=True)
        return j(
            handler, {"ok": True, "path": str(target.relative_to(Path(s.workspace)))}
        )
    except (ValueError, PermissionError, OSError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_file_reveal(handler, body):
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        if not target.exists():
            # Include the resolved server-side path in the error message so
            # the frontend toast can show *which* file the system expected.
            # Useful when a stale session row still references a deleted file
            # (#1764 — Cygnus's screenshot showed a "Failed to reveal: not
            # found" toast that dropped the path entirely, leaving no clue
            # what was missing).
            return bad(handler, f"File not found: {target}", 404)

        system = platform.system()
        if system == "Darwin":
            subprocess.Popen(["open", "-R", str(target)])
        elif system == "Windows":
            subprocess.Popen(["explorer.exe", "/select," + str(target)])
        else:
            # Linux / other — open parent directory
            subprocess.Popen(["xdg-open", str(target.parent)])

        return j(handler, {"ok": True, "path": body["path"]})
    except (ValueError, PermissionError, OSError) as e:
        return bad(handler, _sanitize_error(e))


@answers_http_errors
def _handle_file_path(handler, body):
    """Resolve a relative workspace-rooted path into an absolute on-disk path.

    The right-click "Copy file path" action (#1764) wants to put the
    absolute path on the user's clipboard so they can paste it into a
    terminal, editor, or anywhere else without having to round-trip through
    the OS file browser. The frontend can't compute the absolute path on
    its own — `safe_resolve` joins against the session's workspace root
    which only the server knows. The handler here is a thin lookup; no
    filesystem mutation, no OS-specific dispatch. We do NOT require the
    target to exist (unlike `_handle_file_reveal`) — copying the path of a
    just-deleted file is still useful, and refusing would force callers
    to special-case 404s for an action that cannot fail destructively.
    """
    need(body, "session_id", "path")
    s = session_or_404(body["session_id"])
    try:
        target = safe_resolve(Path(s.workspace), body["path"])
        return j(handler, {"ok": True, "path": str(target)})
    except (ValueError, PermissionError, OSError) as e:
        return bad(handler, _sanitize_error(e))


def _handle_workspace_add(handler, body):
    # Strip surrounding paired quotes BEFORE any further processing — macOS
    # Finder's "Copy as Pathname" wraps paths in single quotes, and users
    # routinely paste those quoted strings into the Add Space input.
    # Doing this at the route entry means every downstream check (blocked
    # system path, validate_workspace_to_add, duplicate detection) sees the
    # cleaned form.
    path_str = _strip_surrounding_quotes(body.get("path", "").strip())
    name = body.get("name", "").strip()
    auto_create = body.get("create", False)
    if not path_str:
        return bad(handler, "path is required")
    # Validate the path is NOT a blocked system root BEFORE any filesystem mutation.
    # This prevents creating orphan directories on rejected paths (#782 review).
    # _is_blocked_system_path honours user-tmp carve-outs (e.g. /var/folders on
    # macOS) so pytest's tmp_path_factory paths and other legit user-tmp dirs
    # still register cleanly.
    candidate = Path(path_str).expanduser().resolve()
    if _is_blocked_system_path(candidate):
        return bad(handler, f"Path points to a system directory: {candidate}")
    # Now safe to create the directory if requested
    if auto_create:
        try:
            candidate.mkdir(parents=True, exist_ok=True)
        except (OSError, PermissionError) as e:
            return bad(handler, f"Could not create directory: {_sanitize_error(e)}")
    # Full validation (exists, is_dir) — should pass now that dir exists
    try:
        p = validate_workspace_to_add(path_str)
    except ValueError as e:
        return bad(handler, str(e))
    wss = load_workspaces()
    if any(w["path"] == str(p) for w in wss):
        return bad(handler, "Workspace already in list")
    wss.append({"path": str(p), "name": name or p.name})
    save_workspaces(wss)
    return j(handler, {"ok": True, "workspaces": wss})


def _handle_workspace_remove(handler, body):
    path_str = body.get("path", "").strip()
    if not path_str:
        return bad(handler, "path is required")
    wss = load_workspaces()
    wss = [w for w in wss if w["path"] != path_str]
    save_workspaces(wss)
    return j(handler, {"ok": True, "workspaces": wss})


def _handle_workspace_rename(handler, body):
    path_str = body.get("path", "").strip()
    name = body.get("name", "").strip()
    if not path_str or not name:
        return bad(handler, "path and name are required")
    wss = load_workspaces()
    for w in wss:
        if w["path"] == path_str:
            w["name"] = name
            break
    else:
        return bad(handler, "Workspace not found", 404)
    save_workspaces(wss)
    return j(handler, {"ok": True, "workspaces": wss})


def _handle_workspace_reorder(handler, body):
    """Reorder workspaces by providing an ordered list of paths.

    Accepts {"paths": ["path1", "path2", ...]}. The workspaces list is
    rewritten so that entries appear in the given order. Any workspace
    not included in the request is appended at the end (preserves data).
    """
    paths = body.get("paths", [])
    if not paths or not isinstance(paths, list):
        return bad(handler, "paths is required and must be a list")
    wss = load_workspaces()
    by_path = {w["path"]: w for w in wss}
    # Build reordered list: given order first, then any omitted entries
    reordered = []
    seen = set()
    for p in paths:
        p = p.strip()
        if p in by_path and p not in seen:
            reordered.append(by_path[p])
            seen.add(p)
    # Append any workspaces not mentioned (safety net)
    for w in wss:
        if w["path"] not in seen:
            reordered.append(w)
    save_workspaces(reordered)
    return j(handler, {"ok": True, "workspaces": reordered})


@answers_http_errors
def _handle_skill_save(handler, body):
    need(body, "name", "content")
    skill_name = body["name"].strip().lower().replace(" ", "-")
    if not skill_name or "/" in skill_name or ".." in skill_name:
        return bad(handler, "Invalid skill name")
    category = body.get("category", "").strip()
    if category and ("/" in category or ".." in category):
        return bad(handler, "Invalid category")
    skills_dir = _active_skills_dir()

    if category:
        skill_dir = skills_dir / category / skill_name
    else:
        skill_dir = skills_dir / skill_name
    # Validate resolved path stays within the active profile skills dir.
    try:
        skill_dir.resolve().relative_to(skills_dir.resolve())
    except ValueError:
        return bad(handler, "Invalid skill path")
    skill_dir.mkdir(parents=True, exist_ok=True)
    skill_file = skill_dir / "SKILL.md"
    skill_file.write_text(body["content"], encoding="utf-8")
    return j(handler, {"ok": True, "name": skill_name, "path": str(skill_file)})


@answers_http_errors
def _handle_skill_delete(handler, body):
    need(body, "name")
    import shutil

    skill_name = str(body["name"]).strip().lower().replace(" ", "-")
    if not skill_name or "/" in skill_name or ".." in skill_name:
        return bad(handler, "Invalid skill name")
    skills_dir = _active_skills_dir()
    matches = [p for p in skills_dir.rglob("SKILL.md") if p.parent.name == skill_name]
    if not matches:
        return bad(handler, "Skill not found", 404)
    skill_dir = matches[0].parent
    shutil.rmtree(str(skill_dir))
    return j(handler, {"ok": True, "name": body["name"]})


@answers_http_errors
def _handle_memory_write(handler, body):
    need(body, "section", "content")
    try:
        from api.profiles import get_active_hermes_home

        mem_dir = get_active_hermes_home() / "memories"
    except ImportError:
        mem_dir = Path.home() / ".jarviscopilot" / "memories"
    mem_dir.mkdir(parents=True, exist_ok=True)
    section = body["section"]
    if section == "memory":
        target = mem_dir / "MEMORY.md"
    elif section == "user":
        target = mem_dir / "USER.md"
    else:
        return bad(handler, 'section must be "memory" or "user"')
    target.write_text(body["content"], encoding="utf-8")
    return j(handler, {"ok": True, "section": section, "path": str(target)})


# ── Code-Memory API ──────────────────────────────────────────────────────────

def _set_global_personality(name: str) -> None:
    """Persist the active persona to config.yaml agent.personality so it applies
    across ALL sessions. Empty name clears it (back to default)."""
    try:
        import yaml
        p = get_active_hermes_home() / "config.yaml"  # active-profile config (what the agent reads)
        cfg = {}
        if p.exists():
            with open(p, encoding="utf-8-sig") as f:
                cfg = yaml.safe_load(f) or {}
        cfg.setdefault("agent", {})
        if name:
            cfg["agent"]["personality"] = name
        else:
            cfg["agent"].pop("personality", None)
        with open(p, "w", encoding="utf-8") as f:
            yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
        try:
            from api.config import reload_config
            reload_config()
        except Exception:
            pass
    except Exception as e:
        print(f"[webui] failed to persist global personality: {e}", flush=True)


@answers_http_errors
def _handle_code_memory_register(handler, body):
    need(body, "slug", "name", "root")
    from agent import code_memory as cm
    slug = cm._sanitize(body["slug"])
    entry = cm.register_project(slug, body["name"], body["root"], body.get("remote", ""), home=get_active_hermes_home())
    return j(handler, {"ok": True, "slug": slug, "entry": entry})


def _handle_code_memory_projects(handler):
    from agent import code_memory as cm
    home = get_active_hermes_home()
    idx = cm.list_all_projects(home=home)  # registered + dirs-with-entries, so it matches stats
    pc = cm.project_counts(home=home)  # {sanitized_slug: {knowledge, sessions}} in one query
    for slug, meta in idx.items():
        c = pc.get(cm._sanitize(slug), {})
        meta["knowledge_count"] = c.get("knowledge", 0)
        meta["sessions_count"] = c.get("sessions", 0)
    return j(handler, {"projects": idx})


def _handle_code_memory_search(handler, parsed):
    from urllib.parse import parse_qs
    from agent import code_memory as cm
    q = parse_qs(parsed.query or "")
    slug = (q.get("project", [""])[0] or "").strip()
    if not slug:
        return bad(handler, "project required")
    kind = (q.get("kind", ["knowledge"])[0] or "knowledge").strip()
    if kind not in cm.KINDS:
        return bad(handler, "valid kind required")
    entry_type = (q.get("type", [""])[0] or "").strip() or None
    query = (q.get("q", [""])[0] or "").strip() or None
    try:
        limit = max(1, min(200, int(q.get("limit", ["20"])[0])))
    except ValueError:
        limit = 20
    try:
        offset = max(0, int(q.get("offset", ["0"])[0]))
    except ValueError:
        offset = 0
    rows = cm.search(slug, kind=kind, entry_type=entry_type, query=query,
                     limit=limit, offset=offset, home=get_active_hermes_home())
    return j(handler, {"slug": slug, "kind": kind, "entries": rows})


def _handle_code_memory_entries(handler, parsed):
    from urllib.parse import parse_qs
    from agent import code_memory as cm
    q = parse_qs(parsed.query or "")
    ids = [i for i in (q.get("ids", [""])[0] or "").split(",") if i.strip()]
    rows = cm.get_by_ids(ids, home=get_active_hermes_home())
    return j(handler, {"entries": rows})


def _handle_code_memory_digest(handler, parsed):
    from urllib.parse import parse_qs
    from agent import code_memory as cm
    q = parse_qs(parsed.query or "")
    slug = (q.get("project", [""])[0] or "").strip()
    if not slug:
        return bad(handler, "project required")
    return j(handler, {"slug": slug, "digest": cm.digest(slug, home=get_active_hermes_home())})


def _handle_code_memory_stats(handler):
    from agent import code_memory as cm
    return j(handler, cm.stats(home=get_active_hermes_home()))


@answers_http_errors
def _handle_code_memory_delete(handler, body):
    need(body, "slug")
    from agent import code_memory as cm
    return j(handler, {"ok": cm.delete_project(body["slug"], home=get_active_hermes_home())})


@answers_http_errors
def _handle_code_memory_delete_entry(handler, body):
    from agent import code_memory as cm
    if body.get("id"):  # precise single-entry delete (preferred)
        return j(handler, {"ok": cm.delete_by_id(body["id"], home=get_active_hermes_home())})
    need(body, "slug", "kind", "ts")
    try:
        removed = cm.delete_entry(body["slug"], body["kind"], body["ts"], home=get_active_hermes_home())
    except ValueError as e:
        return bad(handler, str(e))
    return j(handler, {"ok": True, "removed": removed})


def _notify_target_from_cron():
    """Fall back to the cron auto-delivery target if the caller gave none."""
    try:
        from tools.send_message_tool import _get_cron_auto_delivery_target
        t = _get_cron_auto_delivery_target()
        if t:
            ref = f"{t['platform']}:{t['chat_id']}"
            return ref + (f":{t['thread_id']}" if t.get("thread_id") else "")
    except Exception:
        pass
    return ""


def _handle_notify(handler, body):
    """Push a short notification to a JarvisCopilot-connected messaging channel."""
    text = (body.get("text") or "").strip()
    if not text:
        return bad(handler, "text required")
    target = (body.get("target") or "").strip() or _notify_target_from_cron()
    if not target:
        return j(handler, {"ok": False, "error": "no notify target configured"})
    try:
        import json as _json
        from tools.send_message_tool import send_message_tool
        res = _json.loads(send_message_tool({"action": "send", "target": target, "message": text}))
    except Exception as e:
        return j(handler, {"ok": False, "error": str(e)})
    if res.get("success"):
        return j(handler, {"ok": True})
    return j(handler, {"ok": False, "error": res.get("error", "send failed")})


def _handle_notify_list(handler):
    try:
        from gateway.channel_directory import format_directory_for_display
        return j(handler, {"targets": format_directory_for_display()})
    except Exception as e:
        return j(handler, {"targets": "", "error": str(e)})


@answers_http_errors
def _handle_code_memory_update(handler, body):
    need(body, "id", "content")
    from agent import code_memory as cm
    try:
        res = cm.update_by_id(body["id"], body["content"], body.get("entry_type") or None,
                              home=get_active_hermes_home())
    except ValueError as e:
        return bad(handler, str(e))
    return j(handler, res)


def _handle_code_memory_read(handler, parsed):
    from urllib.parse import parse_qs
    from agent import code_memory as cm
    q = parse_qs(parsed.query or "")
    slug = (q.get("project", [""])[0] or "").strip()
    kind = (q.get("kind", ["knowledge"])[0] or "knowledge").strip()
    try:
        limit = int(q.get("limit", ["50"])[0])
    except ValueError:
        limit = 50
    if not slug or kind not in cm.KINDS:
        return bad(handler, "project and valid kind required")
    rows = cm.read_entries(slug, kind, limit=limit, home=get_active_hermes_home())
    return j(handler, {"slug": slug, "kind": kind, "entries": rows})


@answers_http_errors
def _handle_code_memory_write(handler, body):
    need(body, "slug", "kind", "entry_type", "content")
    from agent import code_memory as cm
    try:
        meta = cm.write_entry(body["slug"], body["kind"], body["entry_type"], body["content"], home=get_active_hermes_home())
    except ValueError as e:
        return bad(handler, str(e))
    return j(handler, {"ok": True, **meta})


# ── MCP Server helpers ──
from api.config import get_config, _save_yaml_config_file, _get_config_path, reload_config

def _mask_secrets(obj):
    """Mask sensitive values in env vars and headers."""
    if not isinstance(obj, dict):
        return obj
    sensitive = ("auth", "token", "key", "secret", "password", "credential")
    masked = {}
    for k, v in obj.items():
        if isinstance(v, str) and any(s in k.lower() for s in sensitive):
            masked[k] = "••••••"
        elif isinstance(v, dict):
            masked[k] = _mask_secrets(v)
        else:
            masked[k] = v
    return masked


def _parse_mcp_enabled(value) -> bool:
    """Parse JarvisCopilot MCP ``enabled`` values without raising on bad config."""
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes", "on"}:
            return True
        if normalized in {"false", "0", "no", "off"}:
            return False
    return True


def _mcp_runtime_status_by_name() -> dict[str, dict]:
    """Return already-known MCP runtime status without starting servers.

    ``tools.mcp_tool.get_mcp_status()`` only reads the existing MCP registry and
    configuration; it does not probe or spawn MCP subprocesses. If JarvisCopilot
    is unavailable, fall back to an empty map so the API remains safe.
    """
    try:
        from tools.mcp_tool import get_mcp_status
        statuses = get_mcp_status()
    except Exception:
        return {}
    if not isinstance(statuses, list):
        return {}
    return {
        str(entry.get("name")): entry
        for entry in statuses
        if isinstance(entry, dict) and entry.get("name")
    }


def _server_summary(name, cfg, runtime_status=None):
    """Return a safe summary of an MCP server config."""
    runtime_status = runtime_status if isinstance(runtime_status, dict) else {}
    out = {"name": name}
    if not isinstance(cfg, dict):
        out.update({
            "transport": "invalid",
            "timeout": 120,
            "connect_timeout": 60,
            "enabled": False,
            "active": False,
            "status": "invalid_config",
            "tool_count": None,
        })
        return out

    enabled = _parse_mcp_enabled(cfg.get("enabled", True))
    connected = bool(runtime_status.get("connected")) if enabled else False
    if "url" in cfg:
        out["transport"] = "http"
        # Mask auth headers
        if "headers" in cfg:
            out["headers"] = _mask_secrets(cfg["headers"])
        out["url"] = cfg["url"]
    elif "command" in cfg:
        out["transport"] = "stdio"
        out["command"] = cfg.get("command", "")
        out["args"] = cfg.get("args", [])
        if "env" in cfg:
            out["env"] = _mask_secrets(cfg["env"])
    else:
        out["transport"] = "invalid"
        enabled = False
        connected = False

    out["timeout"] = cfg.get("timeout", 120)
    out["connect_timeout"] = cfg.get("connect_timeout", 60)
    out["enabled"] = enabled
    out["active"] = connected
    if out["transport"] == "invalid":
        out["status"] = "invalid_config"
    elif not enabled:
        out["status"] = "disabled"
    elif connected:
        out["status"] = "active"
    else:
        out["status"] = "configured"
    out["tool_count"] = runtime_status.get("tools") if runtime_status else None
    return out


def _mcp_safe_display_text(value, *, limit: int) -> str:
    """Return redacted, bounded MCP text safe for WebUI inventory rows."""
    if not isinstance(value, str):
        value = "" if value is None else str(value)
    value = _redact_text(value).strip()
    value = re.sub(r"Authorization:\s*Bearer\s+\S+", "[REDACTED CREDENTIAL]", value, flags=re.I)
    if len(value) > limit:
        value = value[: max(0, limit - 1)].rstrip() + "…"
    return value


def _mcp_schema_type(schema) -> str:
    """Return a compact, non-sensitive display type for a JSON schema node."""
    if not isinstance(schema, dict):
        return "unknown"
    typ = schema.get("type")
    if isinstance(typ, list):
        typ = "/".join(str(t) for t in typ if t)
    if isinstance(typ, str) and typ:
        return typ
    for composite in ("anyOf", "oneOf", "allOf"):
        if isinstance(schema.get(composite), list) and schema[composite]:
            return composite
    if "enum" in schema:
        return "enum"
    return "unknown"


def _mcp_schema_summary(schema, *, limit: int = 12) -> list[dict]:
    """Summarize an MCP input schema without exposing raw defaults/examples.

    The WebUI only needs searchable/displayable argument hints. Returning raw
    JSON Schema can overexpose server-provided defaults, examples, enums, or
    vendor extensions, so this strips each parameter down to name/type/required
    and a redacted description.
    """
    if not isinstance(schema, dict):
        return []
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        return []
    required = schema.get("required")
    required_names = set(required) if isinstance(required, list) else set()
    out = []
    for name, prop in properties.items():
        if len(out) >= limit:
            break
        if not isinstance(name, str):
            continue
        prop = prop if isinstance(prop, dict) else {}
        desc = prop.get("description", "")
        if not isinstance(desc, str):
            desc = ""
        desc = _mcp_safe_display_text(desc, limit=180)
        out.append({
            "name": name,
            "type": _mcp_schema_type(prop),
            "required": name in required_names,
            "description": desc,
        })
    return out


def _mcp_tool_schema_from_payload(tool):
    if not isinstance(tool, dict):
        return {}
    for key in ("parameters", "inputSchema", "input_schema", "schema"):
        value = tool.get(key)
        if isinstance(value, dict):
            if key == "schema" and isinstance(value.get("parameters"), dict):
                return value["parameters"]
            return value
    return {}


def _mcp_tool_summary(name, tool, server_summary):
    """Return a safe global inventory row for one MCP tool."""
    server_summary = server_summary if isinstance(server_summary, dict) else {}
    if isinstance(tool, str):
        tool = {"name": tool}
    elif not isinstance(tool, dict):
        tool = {}
    tool_name = str(tool.get("name") or name or "")
    description = tool.get("description") or ""
    if not isinstance(description, str):
        description = str(description)
    description = _mcp_safe_display_text(description, limit=360)
    return {
        "name": tool_name,
        "server": str(server_summary.get("name") or ""),
        "description": description,
        "active": bool(server_summary.get("active")),
        "enabled": bool(server_summary.get("enabled")),
        "status": server_summary.get("status") or "unknown",
        "schema_summary": _mcp_schema_summary(_mcp_tool_schema_from_payload(tool)),
    }


def _mcp_tools_from_runtime_status(runtime_by_name, server_summaries):
    """Read detailed MCP tool payloads from runtime status when available."""
    tools = []
    if not isinstance(runtime_by_name, dict):
        return tools
    for server_name, runtime in runtime_by_name.items():
        if not isinstance(runtime, dict):
            continue
        raw_tools = runtime.get("tools")
        if not isinstance(raw_tools, list):
            raw_tools = runtime.get("tool_schemas")
        if not isinstance(raw_tools, list):
            continue
        server_summary = server_summaries.get(str(server_name), {"name": str(server_name)})
        for index, tool in enumerate(raw_tools):
            fallback_name = f"{server_name}:{index}"
            summary = _mcp_tool_summary(fallback_name, tool, server_summary)
            if summary["name"]:
                tools.append(summary)
    return tools


def _mcp_tools_from_registry(server_summaries):
    """Read already-registered MCP tool schemas without probing MCP servers."""
    try:
        from tools.registry import registry
    except Exception:
        return []
    tools = []
    try:
        names = registry.get_all_tool_names()
    except Exception:
        return []
    for tool_name in names:
        try:
            toolset = registry.get_toolset_for_tool(tool_name)
        except Exception:
            continue
        if not isinstance(toolset, str) or not toolset.startswith("mcp-"):
            continue
        server_name = toolset[len("mcp-"):]
        schema = registry.get_schema(tool_name) or {}
        server_summary = server_summaries.get(server_name, {
            "name": server_name,
            "enabled": True,
            "active": False,
            "status": "configured",
        })
        tools.append(_mcp_tool_summary(tool_name, schema, server_summary))
    return tools


def _handle_mcp_tools_list(handler):
    """List known MCP tools from already-available runtime inventory only."""
    cfg = get_config()
    servers = cfg.get("mcp_servers", {})
    if not isinstance(servers, dict):
        servers = {}
    runtime = _mcp_runtime_status_by_name()
    server_summaries = {
        str(name): _server_summary(str(name), scfg, runtime.get(str(name)))
        for name, scfg in servers.items()
    }
    tools = _mcp_tools_from_runtime_status(runtime, server_summaries)
    source = "mcp_runtime_status"
    if not tools:
        tools = _mcp_tools_from_registry(server_summaries)
        source = "tool_registry" if tools else "none"
    tools.sort(key=lambda row: (row.get("server", ""), row.get("name", "")))
    unavailable_servers = [
        summary["name"] for summary in server_summaries.values()
        if summary.get("enabled") and not summary.get("active")
    ]
    return j(handler, {
        "tools": tools,
        "total": len(tools),
        "source": source,
        "inventory_scope": "already_known_runtime_only",
        "unavailable_servers": unavailable_servers,
    })


def _handle_mcp_servers_list(handler):
    """List configured MCP servers with safe, read-only runtime visibility."""
    cfg = get_config()
    servers = cfg.get("mcp_servers", {})
    if not isinstance(servers, dict):
        servers = {}
    runtime = _mcp_runtime_status_by_name()
    result = [
        _server_summary(name, scfg, runtime.get(str(name)))
        for name, scfg in servers.items()
    ]
    return j(handler, {
        "servers": result,
        "toggle_supported": False,
        "reload_required": True,
    })


def _handle_mcp_server_delete(handler, name):
    """Delete an MCP server by name."""
    from urllib.parse import unquote
    name = unquote(name)
    if not name:
        return bad(handler, "name is required")
    cfg = get_config()
    servers = cfg.get("mcp_servers", {})
    if not isinstance(servers, dict):
        servers = {}
    if name not in servers:
        return bad(handler, f"MCP server '{name}' not found", 404)
    del servers[name]
    cfg["mcp_servers"] = servers
    _save_yaml_config_file(_get_config_path(), cfg)
    reload_config()
    return j(handler, {"ok": True, "deleted": name})


_MASKED_PLACEHOLDER = "••••••"


def _strip_masked_values(submitted, existing):
    """Remove masked placeholder values from submitted dict, keeping originals."""
    if not isinstance(submitted, dict) or not isinstance(existing, dict):
        return submitted
    cleaned = {}
    for k, v in submitted.items():
        if isinstance(v, str) and v == _MASKED_PLACEHOLDER:
            if k in existing and isinstance(existing[k], str):
                cleaned[k] = existing[k]  # preserve original real value
                continue
        elif isinstance(v, dict) and k in existing and isinstance(existing[k], dict):
            cleaned[k] = _strip_masked_values(v, existing[k])
        else:
            cleaned[k] = v
    return cleaned


def _handle_mcp_server_update(handler, name, body):
    """Add or update an MCP server."""
    from urllib.parse import unquote
    name = unquote(name)
    if not name:
        return bad(handler, "name is required")
    # Validate: must have url (http) or command (stdio)
    server_cfg = {}
    cfg = get_config()
    servers = cfg.get("mcp_servers", {})
    if not isinstance(servers, dict):
        servers = {}
    existing_cfg = servers.get(name, {})
    if body.get("url"):
        server_cfg["url"] = body["url"].strip()
        if body.get("headers"):
            server_cfg["headers"] = _strip_masked_values(body["headers"], existing_cfg.get("headers", {}))
    elif body.get("command"):
        server_cfg["command"] = body["command"].strip()
        if body.get("args"):
            server_cfg["args"] = body["args"] if isinstance(body["args"], list) else [body["args"]]
        if body.get("env"):
            server_cfg["env"] = _strip_masked_values(body["env"], existing_cfg.get("env", {}))
    else:
        return bad(handler, "url or command is required")
    if body.get("timeout") is not None:
        try:
            server_cfg["timeout"] = int(body["timeout"])
        except (ValueError, TypeError):
            pass
    servers[name] = server_cfg
    cfg["mcp_servers"] = servers
    _save_yaml_config_file(_get_config_path(), cfg)
    reload_config()
    return j(handler, {"ok": True, "server": _server_summary(name, server_cfg)})
