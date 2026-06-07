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
                 long_term_recall=None, context_root=None, session_capturer=None,
                 sync_starter=None):
        self.store = store
        self.driver = driver
        self.plugin_dir = plugin_dir
        self.memory_loader = memory_loader          # () -> (memory_text, user_text)
        self.long_term_recall = long_term_recall    # (task) -> str | None
        self.context_root = Path(context_root) if context_root else _default_context_root()
        # (cwd, since_ts) -> claude session uuid | None. None = skip capture
        # (kept injectable so unit tests don't poll the real ~/.claude/projects).
        self.session_capturer = session_capturer
        # sync_starter(session_id, cwd, sync) — kicks the file sync for a session
        # that opted in, regardless of host (server OR desktop). Injected by the
        # webui (coding_routes); None in unit tests / non-sync contexts.
        self.sync_starter = sync_starter

    def _context_path(self, sid: str) -> Path:
        return self.context_root / sid / "JARVIS-CONTEXT.md"

    def _mcp_config_path(self, sid: str, cwd: str) -> str | None:
        """Write a per-session ``.mcp.json`` from the driver's host-appropriate
        code-assist MCP config (next to the context file, OUTSIDE the repo) and
        return its path for ``claude --mcp-config``. Returns None when the driver
        wants no override (e.g. desktop host) or has no ``mcp_servers`` method."""
        mcp_fn = getattr(self.driver, "mcp_servers", None)
        if not callable(mcp_fn):
            return None
        try:
            repo_root = Path(self.plugin_dir).resolve().parent.parent
            cfg = mcp_fn(cwd=cwd, repo_root=str(repo_root))
        except Exception:
            cfg = None
        if not cfg:
            return None
        import json as _json

        path = self.context_root / sid / "mcp.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(_json.dumps(cfg, indent=2), encoding="utf-8")
        return str(path)

    def launch(self, *, cwd, title, initial_prompt, model, project_id=None,
               branch=None, worktree_path=None, worktree=False, repo_path=None,
               skip_permissions=False, sync=None):
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
        sync_config = None
        if sync and (sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
            import json as _json

            sync_config = _json.dumps(sync)
        sid = self.store.create_session(
            project_id=project_id, host=self.driver.name, cwd=cwd, branch=branch,
            tmux_name=tmux_name, source="chat", title=title,
            worktree_path=worktree_path, skip_permissions=skip_permissions,
            sync_config=sync_config)
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
            model=model, initial_prompt=initial_prompt,
            skip_permissions=skip_permissions,
            mcp_config=self._mcp_config_path(sid, cwd))
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
        # 3b. Kick off the bidirectional file sync for ANY host (server OR
        #     desktop) whenever the session opted into syncing. Previously this
        #     only fired via DesktopDriver.on_launched, so a SERVER-host session
        #     with a sync config never synced — the user's exact bug.
        if sync and self.sync_starter and (
                sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
            try:
                self.sync_starter(session_id=sid, cwd=cwd, sync=sync)
            except Exception:
                pass
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

    def restart(self, sid):
        """Restart a stopped session, RESUMING its conversation (claude --continue).

        Re-seeds the memory context (deleted on stop), preserves the session's
        skip-permissions setting, and starts a fresh tmux running
        ``claude --continue`` in the original cwd.
        """
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        cwd = row["cwd"]
        if not cwd or not os.path.isdir(cwd):
            raise ValueError(f"working directory no longer exists: {cwd!r}")
        reason = self.driver.preflight()
        if reason:
            raise RuntimeError(reason)
        # re-seed the memory context (stop() unlinked it)
        mem, usr = self.memory_loader()
        ctx = build_context_markdown(
            memory_text=_scan_memory(mem), user_text=_scan_memory(usr),
            project_name=Path(cwd).name, task=row.get("title") or "", long_term="")
        ctx_path = self._context_path(sid)
        ctx_path.parent.mkdir(parents=True, exist_ok=True)
        ctx_path.write_text(ctx, encoding="utf-8")
        tmux_name = "jc-" + uuid.uuid4().hex[:8]
        launch_argv = self.driver.claude_argv(
            plugin_dir=self.plugin_dir, context_file=str(ctx_path),
            model=None, initial_prompt=None,
            skip_permissions=bool(row.get("skip_permissions")), resume=True,
            mcp_config=self._mcp_config_path(sid, cwd))
        res = self.driver._run(self.driver.tmux_new_argv(
            tmux_name=tmux_name, cwd=cwd, launch_argv=launch_argv))
        rc = getattr(res, "returncode", 0)
        if rc not in (0, None):
            self.store.update_session(sid, status="error", last_activity_at=time.time())
            err = (getattr(res, "stderr", "") or "tmux new-session failed").strip()
            raise RuntimeError(f"failed to restart session: {err}")
        self.store.update_session(sid, tmux_name=tmux_name, status="running",
                                  last_activity_at=time.time())
        return self.store.get_session(sid)

    def delete(self, sid):
        """Stop (if running) and permanently remove a session + its artifacts."""
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        try:
            self.driver._run(self.driver.kill_argv(tmux_name=row["tmux_name"]))
        except Exception:
            pass
        try:
            ctx = self._context_path(sid)
            if ctx.exists():
                ctx.unlink()
                ctx.parent.rmdir()
        except Exception:
            pass
        if row.get("worktree_path"):
            try:
                from agent.coding_worktree import remove_worktree

                remove_worktree(row["worktree_path"], force=True)
            except Exception:
                pass
        self.store.delete_session(sid)

    def update_settings(self, sid, *, skip_permissions=None, sync=None,
                        cwd=None, title=None):
        """Update a session's stored settings (skip-perms, sync, cwd, title).

        Persists immediately; settings that affect the running process
        (skip_permissions, cwd) take effect on the next Restart. Returns the
        updated row.
        """
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        fields = {}
        if skip_permissions is not None:
            fields["skip_permissions"] = 1 if skip_permissions else 0
        if title is not None:
            fields["title"] = title
        if cwd is not None and cwd:
            fields["cwd"] = _resolve_dir(cwd)
        if sync is not None:
            import json as _json

            fields["sync_config"] = (_json.dumps(sync)
                                     if sync.get("enabled") else None)
        if fields:
            self.store.update_session(sid, **fields)
        return self.store.get_session(sid)
