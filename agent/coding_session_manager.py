"""Orchestrates Coding Session lifecycle: store + host driver + memory seed.

This is the keystone the chat tools, WebUI, mobile app, and kanban all call.
It writes the ``JARVIS-CONTEXT.md`` memory seed into the session cwd, records
the session, and drives the host driver to start tmux + claude and to relay
follow-up messages.
"""
from __future__ import annotations

import uuid
from pathlib import Path

from agent.coding_memory_seed import build_context_markdown


class CodingSessionManager:
    def __init__(self, *, store, driver, plugin_dir, memory_loader,
                 long_term_recall=None):
        self.store = store
        self.driver = driver
        self.plugin_dir = plugin_dir
        self.memory_loader = memory_loader          # () -> (memory_text, user_text)
        self.long_term_recall = long_term_recall    # (task) -> str | None

    def launch(self, *, cwd, title, initial_prompt, model, project_id=None,
               branch=None, worktree_path=None):
        tmux_name = "jc-" + uuid.uuid4().hex[:8]
        # 1. seed memory file into the project cwd
        mem, usr = self.memory_loader()
        lt = ""
        if self.long_term_recall:
            try:
                lt = self.long_term_recall(initial_prompt or title) or ""
            except Exception:
                lt = ""
        ctx = build_context_markdown(
            memory_text=mem, user_text=usr, project_name=Path(cwd).name,
            task=initial_prompt or title or "", long_term=lt)
        Path(cwd, "JARVIS-CONTEXT.md").write_text(ctx, encoding="utf-8")
        # 2. record the session
        sid = self.store.create_session(
            project_id=project_id, host=self.driver.name, cwd=cwd, branch=branch,
            tmux_name=tmux_name, source="chat", title=title,
            worktree_path=worktree_path)
        # 3. start tmux + claude, then submit the launch command
        self.driver._run(self.driver.tmux_new_argv(tmux_name=tmux_name, cwd=cwd))
        launch_cmd = self.driver.claude_launch_command(
            plugin_dir=self.plugin_dir, context_file="JARVIS-CONTEXT.md",
            model=model, initial_prompt=initial_prompt)
        self.driver._run(["tmux", "send-keys", "-t", tmux_name, "-l", launch_cmd])
        self.driver._run(["tmux", "send-keys", "-t", tmux_name, "Enter"])
        self.store.update_session(sid, status="running")
        return self.store.get_session(sid)

    def send_message(self, sid, text):
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        for argv in self.driver.send_message_argvs(
                tmux_name=row["tmux_name"], text=text):
            self.driver._run(argv)

    def status(self, sid):
        return self.store.get_session(sid)

    def list(self, status=None):
        return self.store.list_sessions(status=status)

    def stop(self, sid, *, kill=False):
        row = self.store.get_session(sid)
        if not row:
            raise KeyError(sid)
        self.driver._run(["tmux", "kill-session", "-t", row["tmux_name"]])
        self.store.update_session(sid, status="stopped")
