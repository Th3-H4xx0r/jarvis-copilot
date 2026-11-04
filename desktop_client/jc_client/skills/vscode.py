"""vscode_run: open a folder in VS Code and run a command in its own terminal.

Nothing outside VS Code can type into its integrated terminal, so this goes
through the Jarvis Terminal Bridge extension (``jc_client.vscode_bridge``).
Clicking through VS Code to do the same left Claude in a standalone Terminal.
"""
from __future__ import annotations

import os
import subprocess
import time

from jc_client import vscode_bridge
from jc_client.skills import skill

_VSCODE_APP = "Visual Studio Code"
_WINDOW_WAIT = 20.0


def _window_with(bridge, folder: str) -> bool:
    return any(vscode_bridge._containing_len(f, folder) >= 0
               for w in bridge.windows() for f in w.get("folders") or [])


def _open_folder(folder: str) -> None:
    subprocess.run(["open", "-a", _VSCODE_APP, folder], check=False, timeout=15)


@skill(
    "vscode_run",
    "Open a folder in VS Code (or use the window that has it open) and run a command in a "
    "new terminal INSIDE VS Code, e.g. `claude --rc` or `npm test`. Leave command empty to "
    "just open the folder. Says whether a window had to be opened and where it ran.",
    {
        "type": "object",
        "properties": {
            "folder": {"type": "string", "description": "Absolute path (or ~/...) of the project folder."},
            "command": {"type": "string", "description": "Shell command to run in the new VS Code terminal."},
        },
        "required": ["folder"],
    },
)
def vscode_run(folder: str, command: str = "", *, _sleep=time.sleep, _clock=time.monotonic,
               _open=_open_folder) -> dict:
    folder = os.path.expanduser(str(folder or "").strip())
    command = str(command or "").strip()
    if not folder or not os.path.isabs(folder):
        raise ValueError("folder must be an absolute path (or start with ~/)")
    if not os.path.isdir(folder):
        raise ValueError(f"no such folder on this Mac: {folder}")
    bridge = vscode_bridge.current()
    opened = False
    if bridge is None or not _window_with(bridge, folder):
        _open(folder)
        opened = True
        if bridge is None:
            return {"ok": not command, "opened_window": True, "ran": False,
                    "error": ("the Jarvis Terminal Bridge isn't running, so the command could not be "
                              "typed into VS Code; the folder was opened") if command else None}
        end = _clock() + _WINDOW_WAIT
        while not _window_with(bridge, folder):
            if _clock() >= end:
                return {"ok": False, "opened_window": True, "ran": False,
                        "error": ("VS Code opened the folder but its window never connected to Jarvis "
                                  "(is the Jarvis Terminal Bridge extension enabled?)")}
            _sleep(0.5)
    if not command:
        return {"ok": True, "opened_window": opened, "ran": False, "folder": folder}
    if not bridge.run_in_terminal(folder, command):
        return {"ok": False, "opened_window": opened, "ran": False,
                "error": "VS Code didn't accept the command"}
    return {"ok": True, "opened_window": opened, "ran": True, "folder": folder,
            "terminal": "a new 'Jarvis' terminal in VS Code", "command": command}
