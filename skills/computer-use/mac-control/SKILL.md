---
name: mac-control
description: "Do a task on Pranav's Mac in one try, then check it."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [mac, computer-use, desktop, automation, computer_do]
    related_skills: [mac-app-recipes, mac-screen-look, mac-dev-setup, web-task-router]
---

# Mac Control Skill

The playbook for anything Pranav wants done on his MacBook: opening apps or
pages, clicking through an app, typing, changing a setting. It picks the
fastest reliable route (shell or an app's own tool before clicking), checks
the Mac can be driven at all, and reports only what it saw happen. Per-app
routes live in `mac-app-recipes`; reading his screen lives in `mac-screen-look`.

## When to Use

- He says "on my Mac", "on my MacBook", "on my laptop", "computer control",
  "visual control", or names a Mac app ("open Notes", "in VS Code").
- He's not at the Mac and wants something done there ("I'm not near my Mac,
  do this for me").
- A follow-up in a chat where Mac control was already in use ("try again",
  "continue", "read the page").

Not for: a question you can just answer (see Step 1), or anything on his
phone (the iPhone device tools) or the server browser (`web-task-router`).

## Prerequisites

- The Mac is paired and online: device tools show "Pranavs-MacBook-Pro".
  Device tools are `device_<name>` and take a `device` argument. Pass the
  Mac's name exactly as the tool's "Available:" list shows it. Never leave it
  out: without it the call may go to the iPhone.
- Tools may be deferred. Load them in one call first, e.g.
  `tool_search` `select:computer_do,device_run_shell,device_ui_look,device_ui_do,device_screenshot`.

## How to Run

Route ladder, fastest first. Take the first rung that can do the task:

| Rung | Tool | Use for |
|---|---|---|
| 1 | an app's own tool | `device_messages_send`, `device_spotify_play`, `device_media_control`, `device_volume_set`, `device_lock_screen`, `device_open_url`, `device_open_app` |
| 2 | `device_run_shell` | `open -a`, `open <url>`, `osascript`, `pmset`, `defaults`, `shortcuts run`, reading files |
| 3 | `computer_do` | multi-step UI work inside an app (fills, menus, buttons) |
| 4 | `device_ui_look` + `device_ui_do` | one or two precise moves, or continuing after `computer_do` stopped |
| 5 | `device_mouse_click` / `device_key_press` | last resort, raw x/y from a fresh screenshot |

## Quick Reference

- Open a page on the Mac: `device_open_url {url, device}`. Build the full
  URL with the search already in it; never type a URL into a browser.
- Open an app: `device_open_app {name, device}` (exact app name, e.g.
  "Brave Browser", "Visual Studio Code", "System Settings").
- Specific browser: `device_run_shell {cmd: "open -a 'Brave Browser' 'https://…'"}`.
- What's in front: `device_current_window`; all windows: `device_list_windows` (no arguments).
- Battery / power: `device_run_shell {cmd: "pmset -g batt"}`.
- Is the Mac locked? `device_run_shell {cmd: "ioreg -n Root -d1 | grep -c CGSSessionScreenIsLocked"}` → `1` locked, `0` unlocked.
- `computer_do {goal, app, steps:[{do, text?, url?, app?}]}`: goal is what should be
  true at the end, in your own words.

## Procedure

1. **Answer-first check.** If he asked a question ("how far is…", "what's my
   battery", "what's the price"), get the answer with a tool that doesn't touch his
   screen (`web_search`, `device_run_shell`, an API) and just tell him. Open
   things on the Mac only when he asked to see it or to have it open.
2. **Pick the device he named.** "On my phone" → the iPhone, "on my Mac" → the Mac,
   no device and nothing to show → the server. If he corrected the device earlier in
   this chat, keep his correction.
3. **Preflight (one call).** Before UI work (rungs 3–5), run the lock check above.
   - Locked → stop and tell him it's locked. Offer the iPhone's Unlock Mac
     (Agents → Mac). Never type his password; the Unlock flow does that after
     Face ID.
   - Otherwise go on. `computer_do` works even when another app is in front and
     on another Space.
4. **Write the task yourself.** Never pass his raw words as the `computer_do` goal.
   Turn "send me ss of mac" into a screenshot (see `mac-screen-look`). Turn "add
   these to my todo list" into the app he uses for todos (ask once if unknown). Fix
   voice mishearings ("braid browser" = Brave Browser). The goal names the end
   state; `steps` carry every exact text to type.
5. **Do it with the lowest rung that fits.** One `computer_do` per sub-goal, not one
   per click.
6. **One stall = switch method.** If a call returns `stuck`, an error, "did nothing",
   or the same screen twice:
   - don't repeat it the same way;
   - drop one rung (shell or an app tool) or continue precisely with
     `device_ui_look` → `device_ui_do`;
   - after two different methods fail, stop and tell him what's on screen and
     what blocked it.
7. **Verify before "done".** Read the result off the final screenshot or with a read
   (`device_current_window`, the app's own state, `device_ui_look`). Say what you
   *saw*:
   - not "Done — Messages" but "Sent 'running late' to Mom; it shows as Delivered";
   - if it stopped because he was using the Mac, say exactly that.
8. **Show him.** If he wants to see the result, include the screenshot's
   `show_with` line in the reply (see `mac-screen-look`).

## Pitfalls

- **Clipboard:** never press cmd+a/cmd+c and never read the clipboard
  (`device_clipboard_read`) unless he asked for clipboard work. In Oct 2026 this
  copied an API key into the chat.
- **Typing while he types:** if `computer_do` refuses because he's using the Mac,
  wait or ask. Don't fight him for the keyboard.
- **Raw clicks:** `device_chrome_click` takes `{element, ref}` from a snapshot,
  not x/y. Coordinates belong to `device_mouse_click`.
- **Wrong window or app:** keys go to the frontmost app. Anchor every task with
  `app` and never send keys after he switches apps.
- **Admin password prompts** (sudo, installer, System Settings lock) can't be
  typed by you. Say a password prompt is up and ask him to approve it at the Mac.
- **Don't loop the consent question.** Once he has asked for his Mac in this chat,
  don't ask again for follow-ups.
- **Don't open the Screenshot app, TextEdit or Health** because a word in his
  message matched an app name.

## Verification

- The reply names the device it actually ran on (`ran_on` in the tool result).
- Every "done" claim is backed by something read after the action.
- No more than two attempts with the same method; a third try uses a different rung.
