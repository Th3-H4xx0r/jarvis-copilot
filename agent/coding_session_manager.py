"""Orchestrates Coding Session lifecycle: store + host driver + memory seed.

This is the keystone the chat tools, WebUI, mobile app, and kanban all call.
It scans + seeds Jarvis memory into a per-session ``JARVIS-CONTEXT.md`` kept
OUTSIDE the project (so personal memory never lands in the project's git repo),
records the session, drives the host driver to start tmux + claude, and relays
follow-up messages.

Known Phase-1 limitation: ``claude_session_id`` is not yet captured (that needs
watching ``~/.claude/projects`` for the new transcript); until then a stopped
session can't be ``--resume``d. Tracked for a later phase.
"""
from __future__ import annotations

import os
import time
import uuid
from pathlib import Path

from agent.coding_memory_seed import build_context_markdown


def _resolve_dir(p: str | None) -> str:
    """Expand ``~``, make absolute. ('' for falsy input.)"""
    if not p:
        return ""
    return os.path.abspath(os.path.expanduser(str(p)))


def _default_context_root() -> Path:
    try:
        from jarviscopilot_constants import get_hermes_home

        root = Path(get_hermes_home())
    except Exception:
        root = Path(os.path.expanduser("~/.jarviscopilot"))
    return root / "coding_sessions"


def _scan_memory(text: str) -> str:
    """Redact memory that trips the injection/exfil scanner before seeding it
    into a launched agent's system-prompt context."""
    if not text:
        return ""
    try:
        from tools.memory_tool import _scan_memory_content

        if _scan_memory_content(text) is not None:
            return "_(omitted — failed safety scan)_"
    except Exception:
        # If the scanner can't be loaded, fail safe by omitting rather than
        # forwarding unscanned content into the launched agent.
        return "_(omitted — safety scan unavailable)_"
    return text


class CodingSessionManager:
    def __init__(self, *, store, driver, plugin_dir, memory_loader,
                 long_term_recall=None, context_root=None, session_capturer=None):
        self.store = store
        self.driver = driver
        self.plugin_dir = plugin_dir
        self.memory_loader = memory_loader          # () -> (memory_text, user_text)
        self.long_term_recall = long_term_recall    # (task) -> str | None
        self.context_root = Path(context_root) if context_root else _default_context_root()
        # (cwd, since_ts) -> claude session uuid | None. None = skip capture
        # (kept injectable so unit tests don't poll the real ~/.claude/projects).
        self.session_capturer = session_capturer

    def _context_path(self, sid: str) -> Path:
        return self.context_root / sid / "JARVIS-CONTEXT.md"

    def launch(self, *, cwd, title, initial_prompt, model, project_id=None,
               branch=None, worktree_path=None, worktree=False, repo_path=None):
        # Optionally isolate the session in a fresh git worktree so parallel
        # sessions on one repo don't collide.
        if worktree:
            repo_path = _resolve_dir(repo_path)
            if not repo_path or not os.path.isdir(repo_path):
                raise ValueError("worktree=True requires repo_path to be an existing directory")
            from agent.coding_worktree import add_worktree

            wt_branch = branch or ("jc/" + uuid.uuid4().hex[:6])
            cwd = add_worktree(repo_path, wt_branch)
            worktree_path = cwd
            branch = wt_branch
        else:
            # Accept ``~``, relative paths, and not-yet-existing dirs: expand,
            # absolutize, and create the directory on demand (the user asked for
            # this — no more "must be an existing absolute directory").
            cwd = _resolve_dir(cwd)
            if not cwd:
                raise ValueError("a working directory is required")
            try:
                os.makedirs(cwd, exist_ok=True)
            except OSError as e:
                raise ValueError(f"could not create working directory {cwd!r}: {e}")
        # Validate model at the chokepoint so every entrypoint (chat tool AND
        # the HTTP route, which bypasses the tool layer) rejects a bad/injection
        # model identically instead of silently falling back.
        if model:
            from agent.coding_host_drivers import is_valid_model

            if not is_valid_model(model):
                raise ValueError(f"invalid model: {model!r}")
        # Host readiness: auto-installs tmux if missing, checks claude — so the
        # user gets a clear message instead of a raw "[Errno 2] … 'tmux'".
        reason = self.driver.preflight()
        if reason:
            raise RuntimeError(reason)
        tmux_name = "jc-" + uuid.uuid4().hex[:8]
        # 1. record the session first (so the context dir can be session-scoped)
        sid = self.store.create_session(
            project_id=project_id, host=self.driver.name, cwd=cwd, branch=branch,
            tmux_name=tmux_name, source="chat", title=title,
            worktree_path=worktree_path)
        # 2. build + write the memory seed OUTSIDE the project repo
        mem, usr = self.memory_loader()
        lt = ""
        if self.long_term_recall:
            try:
                lt = self.long_term_recall(initial_prompt or title) or ""
            except Exception:
                lt = ""
        ctx = build_context_markdown(
            memory_text=_scan_memory(mem), user_text=_scan_memory(usr),
            project_name=Path(cwd).name, task=initial_prompt or title or "",
            long_term=_scan_memory(lt))
        ctx_path = self._context_path(sid)
        ctx_path.parent.mkdir(parents=True, exist_ok=True)
        ctx_path.write_text(ctx, encoding="utf-8")
        # 3. start tmux running claude directly (argv, no shell)
        launch_argv = self.driver.claude_argv(
            plugin_dir=self.plugin_dir, context_file=str(ctx_path),
            model=model, initial_prompt=initial_prompt)
        since = time.time()
        res = self.driver._run(self.driver.tmux_new_argv(
            tmux_name=tmux_name, cwd=cwd, launch_argv=launch_argv))
        rc = getattr(res, "returncode", 0)
        if rc not in (0, None):
            # Roll back the worktree WE created so a failed launch doesn't leave
            # an orphan worktree + dangling branch + error row pointing at it.
            if worktree and worktree_path:
                try:
                    from agent.coding_worktree import remove_worktree

                    remove_worktree(worktree_path, force=True)
                except Exception:
                    pass
                self.store.update_session(sid, worktree_path=None)
            self.store.update_session(sid, status="error", last_activity_at=time.time())
            err = (getattr(res, "stderr", "") or "tmux new-session failed").strip()
            raise RuntimeError(f"failed to start session: {err}")
        self.store.update_session(sid, status="running", last_activity_at=time.time())
        # 4. best-effort: recover the claude session UUID (enables --resume +
        #    transcript/subagent correlation). Injectable; skipped if not set.
        if self.session_capturer:
            try:
                cid = self.session_capturer(cwd, since)
                if cid:
                    self.store.update_session(sid, claude_session_id=cid)
            except Exception:
                pass
        return self.store.get_session(sid)

    def subagents(self, sid):
        """Subagents the session has spawned (parsed from its transcript)."""
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        cid = row.get("claude_session_id")
        if not cid:
            return []
        try:
            from agent.coding_session_capture import (
                claude_projects_dir, encode_project_dir)
            from agent.coding_subagent_tracker import parse_subagents

            path = claude_projects_dir() / encode_project_dir(row["cwd"]) / f"{cid}.jsonl"
            return parse_subagents(str(path))
        except Exception:
            return []

    def send_message(self, sid, text):
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        for argv in self.driver.send_message_argvs(
                tmux_name=row["tmux_name"], text=text):
            self.driver._run(argv)
        self.store.update_session(sid, last_activity_at=time.time())

    def status(self, sid):
        return self.store.get_session(sid)

    def list(self, status=None):
        return self.store.list_sessions(status=status)

    def stop(self, sid, *, kill=False):
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        self.driver._run(self.driver.kill_argv(tmux_name=row["tmux_name"]))
        self.store.update_session(sid, status="stopped", last_activity_at=time.time())
        # best-effort cleanup of the PII-bearing context file
        try:
            ctx = self._context_path(sid)
            if ctx.exists():
                ctx.unlink()
                ctx.parent.rmdir()
        except Exception:
            pass
        # best-effort cleanup of the session's git worktree
        if row.get("worktree_path"):
            try:
                from agent.coding_worktree import remove_worktree

                remove_worktree(row["worktree_path"], force=True)
            except Exception:
                pass
