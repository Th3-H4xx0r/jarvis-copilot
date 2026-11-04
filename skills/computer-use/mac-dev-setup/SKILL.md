---
name: mac-dev-setup
description: "Open projects, run Claude and commands in Mac VS Code."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [mac, vscode, claude-code, terminal, dev, computer-use]
    related_skills: [mac-control, mac-app-recipes]
---

# Mac Dev Setup Skill

Getting Pranav's coding work going on his MacBook: open a project in VS Code,
start Claude Code (often with Remote Control, `claude --rc`) or any command in
VS Code's *own* terminal, run builds/tests, and report what happened. It uses
the Jarvis Terminal Bridge extension instead of clicking. Clicking once
left Claude in a standalone Terminal instead of VS Code.

## When to Use

- "Open <project> in VS Code", "start Claude on <project> on my Mac",
  "run claude --rc in VS Code", "run the tests in VS Code".
- "Check if the build passes on my Mac", "what branch is <project> on".

Not for: a coding session he wants on the **server** (use `coding_session_launch`).
His words decide: "on my Mac" / "in VS Code" → Mac; "start a session" with no
place → ask once, offering the server as the default.

## Prerequisites

- Mac online; Mac device tools take `device` (the Mac's exact name from the
  tool's "Available:" list).
- `device_vscode_run` exists once the Mac's jc-client is current. If it's missing,
  fall back to the computer_do route in Pitfalls.
- Projects live under `~/PranavFiles/coding-projects/` (e.g. `jarvis-copilot`).
  Find one by name:
  `device_run_shell {cmd: "ls -d ~/PranavFiles/coding-projects/*/ | grep -i <name>"}`.
- VS Code CLI (not on PATH): `"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"`.
- Claude Code: `~/.local/bin/claude`.

## How to Run

| Ask | Call |
|---|---|
| Open a project | `device_vscode_run {folder: "~/PranavFiles/coding-projects/<p>"}` |
| Claude in VS Code | `device_vscode_run {folder, command: "claude --rc"}` |
| Claude with a task | `device_vscode_run {folder, command: "claude --rc \"<task in one line>\""}` |
| Run tests/build where he can watch | `device_vscode_run {folder, command: "<cmd>"}` |
| Read-only checks (branch, status, a quick test) | `device_run_shell {cmd: "cd <folder> && git status -sb"}` |

`device_vscode_run` opens the folder if no VS Code window has it, waits for the
window, then runs the command in a new terminal named "Jarvis" inside VS Code.
The result says `opened_window` and `ran`.

## Quick Reference

- Find the project folder first. Never guess a path from the spoken name.
- Quote a task prompt inside `command` with escaped double quotes. Keep it on one line.
- For output you need back (test results, `git log`), use `device_run_shell` with a
  `timeout`; `device_vscode_run` does not return the terminal's output.
- A Remote Control session shows up in his Claude app and in Jarvis's Agents tab.

## Procedure

1. Resolve the folder with one `device_run_shell` `ls`. If several match, ask
   which one.
2. If he wants it visible or interactive (Claude, a dev server, a watch task), use
   `device_vscode_run`. If he only wants an answer (does it build? which branch?),
   use `device_run_shell` and report the output.
3. Check the result. `ran: true` means the command was typed into VS Code's
   terminal. For Claude, wait a few seconds, then confirm it's running:
   `device_run_shell {cmd: "pgrep -fl 'claude --rc' | head -3"}`.
4. Reply with where it ran ("in VS Code, jarvis-copilot window, new Jarvis
   terminal") and anything he must do (e.g. "approve the folder-trust prompt").

## Pitfalls

- **Bridge missing** (`device_vscode_run` errors about the bridge, or the tool
  doesn't exist): fall back to `computer_do`:
  - `app: "Visual Studio Code"`
  - steps: open the folder with `device_run_shell` and the `code` CLI first
  - then `do: "open a new terminal with ctrl+shift+backtick"`
  - then `do: "type the command and press return", text: "claude --rc"`
  - verify with `device_ui_look` that the terminal panel shows it.
- Never use `open -a Terminal` or `osascript … Terminal do script` when he said VS Code.
- `claude` first-run prompts (trust this folder, login) need him. Say so instead of
  pressing keys blindly.
- Don't start a second Claude in the same folder if one is already running there
  (`pgrep -fl claude`). Ask whether to reuse it.
- Long builds: don't block on `device_run_shell` past its timeout. Run them in VS Code
  and check back.

## Verification

- `device_vscode_run` returned `ran: true` (or `ok: true` for just opening).
- For Claude: a `claude` process exists for that folder.
- The reply names the window/folder, not just "Done".
