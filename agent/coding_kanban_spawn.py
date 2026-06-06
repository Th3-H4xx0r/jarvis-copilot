"""kanban -> Claude Code spawn function for JarvisCopilot Coding Sessions.

The kanban dispatcher (:func:`jarviscopilot_cli.kanban_db.dispatch_once`)
spawns each claimed card through a pluggable ``spawn_fn`` with the signature::

    spawn_fn(task, workspace, *, board=None) -> Optional[pid_or_result]

The default (:func:`jarviscopilot_cli.kanban_db._default_spawn`) fires a
``hermes chat`` subprocess. :func:`make_claude_spawn_fn` builds an alternative
``spawn_fn`` that, for cards explicitly flagged ``runner == "claude"``, instead
launches a Phase-1 Coding Session via :class:`CodingSessionManager.launch`.
Every other card is delegated unchanged to a ``fallback`` spawn_fn, so this
wrapper composes cleanly in front of the existing dispatcher behaviour.

This module is pure stdlib and accesses the card via ``.get(...)``: cards are
treated as dict-like (the suite passes plain dicts; the live dispatcher can
pass an object exposing the same keys via a thin adapter).

Assumptions (see module docstring + the returned function below):

* **Runner flag** — a card opts into Claude Code only when its ``runner`` field
  equals the exact string ``"claude"``. Absent / empty / ``None`` / any other
  value (including ``"Claude"`` or ``"claude-code"``) routes to the fallback.
* **Prompt composition** — if the card carries a prebuilt ``worker_context``
  string we use it verbatim as the body of the prompt; otherwise we synthesise
  one from ``title`` + ``body``. Either way we append an explicit instruction
  to work the kanban card (by id) so the launched agent knows its job.
* **cwd resolution** — ``worktree_path`` (isolated worktree) wins, then the
  card's ``workspace_path``, then the dispatcher-provided ``workspace``. A
  Claude card with no resolvable cwd is a hard error (ValueError) — a coding
  session must run somewhere.
"""
from __future__ import annotations


def _field(task, key, default=None):
    """Read a card field whether the card is dict-like or an object.

    The test suite passes plain dicts; the live ``dispatch_once`` passes a
    ``Task`` object exposing the same fields as attributes. Support both.
    """
    if hasattr(task, "get"):
        try:
            return task.get(key, default)
        except TypeError:
            pass
    return getattr(task, key, default)


def _wants_claude(task) -> bool:
    """Return True iff this card is flagged to run under Claude Code.

    The opt-in is exact: ``runner == "claude"``. Anything else (missing key,
    empty string, ``None``, ``"Claude"``, ``"claude-code"``, ...) is False so
    the card falls through to the default hermes spawn.
    """
    return _field(task, "runner") == "claude"


def _build_initial_prompt(task) -> str:
    """Compose the launched agent's initial prompt from the card.

    Prefers a prebuilt ``worker_context`` blob; otherwise stitches
    ``title`` + ``body``. Always appends an explicit kanban-work instruction
    referencing the card id.
    """
    context = _field(task, "worker_context")
    if context:
        base = str(context)
    else:
        title = _field(task, "title") or ""
        body = _field(task, "body", "") or ""
        base = title
        if body:
            base = f"{title}\n\n{body}" if title else body

    task_id = _field(task, "id")
    ref = f" (kanban card {task_id})" if task_id else ""
    instruction = (
        f"You are working a JarvisCopilot kanban task{ref}. "
        "Complete the work described above, then mark the card done."
    )

    if base:
        return f"{base}\n\n{instruction}"
    return instruction


def make_claude_spawn_fn(manager, *, fallback, link=None):
    """Build a kanban ``spawn_fn`` that routes Claude cards to ``manager``.

    Parameters
    ----------
    manager:
        Object exposing ``launch(*, cwd, title, initial_prompt, model, ...)``
        and returning a session row dict containing an ``id``
        (a :class:`CodingSessionManager` in production; a fake in tests).
    fallback:
        Callable ``fallback(task, workspace, *, board=None)`` used for every
        non-Claude card. Its return value is propagated unchanged.
    link:
        Optional callable ``link(*, task_id, session_id)`` invoked after a
        successful launch to associate the new session with the card.

    Returns
    -------
    callable
        ``spawn_fn(task, workspace, *, board=None)`` matching the kanban
        dispatcher's expected signature.
    """

    def spawn_fn(task, workspace, *, board=None):
        if not _wants_claude(task):
            return fallback(task, workspace, board=board)

        cwd = (_field(task, "worktree_path") or _field(task, "workspace_path")
               or workspace)
        if not cwd:
            raise ValueError(
                f"claude card {_field(task, 'id')!r} has no workspace: set "
                "worktree_path / workspace_path or pass a dispatcher workspace"
            )

        session = manager.launch(
            cwd=cwd,
            title=_field(task, "title") or _field(task, "id"),
            initial_prompt=_build_initial_prompt(task),
            model=_field(task, "model_override"),
        )

        if link is not None:
            link(task_id=_field(task, "id"), session_id=session.get("id"))

        return session

    return spawn_fn
