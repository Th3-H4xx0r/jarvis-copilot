---
name: computer-tasks
description: "Plan and do small multi-step tasks on his PC or Mac."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [pc, mac, computer-use, wake, unlock, apps, games, computer_do]
    related_skills: [mac-control, mac-app-recipes, mac-screen-look]
---

# Computer Tasks Skill

The planning framework for small jobs on Pranav's Windows PC or MacBook that take a
few steps: "turn on my PC and launch Warzone", "open Discord on the PC", "close the
game and put the PC to sleep". It plans like a person: which computer, is it on, is it
unlocked, which app, do it, check it. Installs and setup go to the IT agent instead;
Mac-only routes live in `mac-control`.

## When to Use

- A small task on a computer, often several parts in one ask ("turn on… and launch…").
- A follow-up in a chat that's about one computer ("launch it now", "open Discord too").
- He doesn't say which computer. Infer it; never ask "which PC?" when the chat or the app says.

Not for: installing or fixing software (the IT agent), questions you can just answer,
or anything on his phone.

## Prerequisites

- His PC (`pranav-computer`, Windows) and Mac (`Pranavs-MacBook-Pro.local`) run jc-client.
- A sleeping computer is fine: `computer_do`, the device tools and the power tool's wake
  wake it and wait until it's ready (up to 2 minutes). No separate wake call needed first.
- A locked screen is fine: the tools unlock it before driving the screen (his Face ID on
  the iPhone, or none while he's given Jarvis unlock permission).

## How to Run

The plan, every time (one line each in your head, not out loud):

1. **Which computer.** His words first, then this chat (a PC chat stays on the PC), then
   the app: Windows games and launchers (Battle.net, Call of Duty/Warzone, Steam games)
   are on the PC; Mac apps are on the Mac. Pass it: `computer_do {computer: "PC"}`, or
   `device: "pranav-computer"` on device tools.
2. **On.** Asleep → just call the tool; it wakes it and waits.
3. **Unlocked.** Locked → the tool unlocks first. If it says the unlock waits for Face ID,
   tell him once in one line; don't retry in a loop.
4. **The app.** Use its everyday name; the PC finds it like the Start menu does
   ("Warzone" → Call of Duty, started through Battle.net).
5. **Do it, fastest route first:** an app's own tool → `device_open_app` →
   `computer_do` with short `steps` for anything inside an app.
6. **Check.** Look before saying done: a game shows its window after 30–60 s;
   `device_screenshot` or `device_ui_look` when unsure.
7. **Report** what happened in one line, honestly (done, or exactly where it stopped).

## Quick Reference

| He says | Do |
|---|---|
| "turn on my PC" | the power tool's wake (waits until it's on and unlocked) |
| "launch Warzone" (PC chat) | `device_open_app {name: "Call of Duty", device: "pranav-computer"}` |
| "open Discord on the PC" | `device_open_app {name: "Discord", device: "pranav-computer"}` |
| "close the game" | `device_quit_app {name: "cod", device: "pranav-computer"}` |
| "is it locked?" | `device_screen_locked {device: …}` |
| "lock it" | `device_lock_screen {device: …}` |
| several clicks inside an app | `computer_do {goal, computer, app, steps: [{do, app?, text?}]}` |

## Procedure

Worked examples (the plan applied):

1. **"Can you turn on my PC and launch Warzone?"**
   Which: "my PC" → PC. On/unlocked: handled by the call. App: Warzone = Call of Duty via
   Battle.net. Do: `device_open_app {name: "Warzone", device: "pranav-computer"}`. Check:
   wait for its window (~30–60 s; `device_ui_look {app: "Call of Duty"}`). Report:
   "Your PC is on and Warzone is starting."
2. **"Launch it now."** (right after asking about the PC) Which: this chat → PC. Same call
   as above. Never refuse a wake for lack of a power word; never ask which computer.
3. **"Open Discord and join the gaming channel."** (PC chat) `computer_do {goal: "In
   Discord's gaming voice channel", computer: "PC", app: "Discord", steps: [{do: "open the
   server list"}, {do: "click the gaming voice channel"}]}`.
4. **"Play lo-fi on my Mac."** Which: Mac. App tool first: `device_spotify_play
   {query: "lo-fi", device: "Pranavs-MacBook-Pro.local"}`.
5. **"Close the game and put the PC to sleep."** `device_quit_app {name: "cod", device:
   "pranav-computer"}`, then the power tool's sleep (his own words asked for it).

## Pitfalls

- Sending a PC task to the Mac because this message didn't say "PC" — read the chat.
- Giving up on "not connected": the tools wake the computer; if a wake really fails, say so
  once, with the reason the tool gave.
- Repeating the same failing step. Change the route (app tool ↔ `device_open_app` ↔
  `computer_do`) or stop and say where it got to.
- Saying "done" before checking; games and launchers take tens of seconds.
- Sleeping or locking without his own words asking for it.

## Verification

- The app's window is found (`device_ui_look {app: …}`) or visible in `device_screenshot`.
- For a game: its process window appears within ~60 s of the launch.
- Your reply says exactly what you saw, nothing more.
