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
few steps: "turn on my PC and open Discord", "start a game", "close it and put the PC
to sleep". It plans like a person: which computer, is it on, is it unlocked, which app,
do it while watching the screen, check it. Nothing here is specific to one app: names
come from what's installed, and what to click comes from what's on screen. Installs and
setup go to the IT agent instead; Mac-only routes live in `mac-control`.

## When to Use

- A small task on a computer, often several parts in one ask ("turn on… and open…").
- A follow-up in a chat that's about one computer ("do it now", "open that too").
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
   where the app is installed (`device_installed_apps`). Pass it: `computer_do {computer:
   "PC"}`, or `device: "pranav-computer"` on device tools.
2. **On.** Asleep → just call the tool; it wakes it and waits.
3. **Unlocked.** Locked → the tool unlocks first. If it says the unlock waits for Face ID,
   tell him once in one line; don't retry in a loop.
4. **The app.** He may use a nickname or a product's own name while the computer lists it
   under another (a series, a maker). Map it from `device_installed_apps`; an open that
   finds nothing returns the installed list too — pick from it, don't guess again.
5. **Do it, fastest route that reaches the goal:** an app's own tool → `device_open_app`
   when opening is the whole job → `computer_do` when anything has to happen after it
   opens. State the goal as the end state ("<app> is running", "in the voice channel"):
   `computer_do` watches the screen and re-plans when something else shows up (a
   launcher, a start page, a sign-in), like a person would.
6. **Check.** Look before saying done (`device_screenshot` / `device_ui_look`); big apps
   take tens of seconds to show a window.
7. **Report** what happened in one line, honestly (done, or exactly where it stopped).

## Quick Reference

| He says | Do |
|---|---|
| "turn on my PC" | the power tool's wake (waits until it's on and unlocked) |
| "open <app> on the PC" | `device_open_app {name: "<app>", device: "pranav-computer"}` |
| "start / play <something>" | `computer_do {goal: "<it> is running", computer, steps: [{do: "open <it>", app: "<it>"}]}` |
| "what's on my PC?" | `device_installed_apps {device: …}` |
| "close <app>" | `device_quit_app {name: "<process>", device: …}` |
| "is it locked?" / "lock it" | `device_screen_locked` / `device_lock_screen` |
| several clicks inside an app | `computer_do {goal, computer, app, steps: [{do, app?, text?}]}` |

## Procedure

Worked examples (the plan applied):

1. **"Turn on my PC and start <a game>."**
   Which: "my PC" → PC. On/unlocked: handled by the call. App: the name he used, or the
   installed entry it maps to. Do: `computer_do {goal: "<game> is running", computer:
   "PC", steps: [{do: "open <game>", app: "<game>"}]}` — if its launcher opens instead,
   the run sees that and plans the rest (pick the game, press its play button) from the
   screen. Report what the screen shows.
2. **"Do it now."** (right after asking about the PC) Which: this chat → PC. Same call
   as above. Never refuse a wake for lack of a power word; never ask which computer.
3. **"Open Discord and join the gaming channel."** (PC chat) `computer_do {goal: "In
   Discord's gaming voice channel", computer: "PC", app: "Discord", steps: [{do: "open the
   server list"}, {do: "click the gaming voice channel"}]}`.
4. **"Play lo-fi on my Mac."** Which: Mac. App tool first: `device_spotify_play
   {query: "lo-fi", device: "Pranavs-MacBook-Pro.local"}`.
5. **"Close it and put the PC to sleep."** `device_quit_app` with the app's process
   (`device_list_windows` shows it), then the power tool's sleep (his own words asked for it).

## Pitfalls

- Sending a PC task to the Mac because this message didn't say "PC" — read the chat.
- Giving up on "not connected": the tools wake the computer; if a wake really fails, say so
  once, with the reason the tool gave.
- Using `device_open_app` for a goal that needs clicks after opening — it stops at "opened".
- Repeating the same failing step. Change the route (app tool ↔ `device_open_app` ↔
  `computer_do`) or stop and say where it got to.
- Saying "done" before checking the screen.
- Sleeping or locking without his own words asking for it.

## Verification

- The app's window is found (`device_ui_look {app: …}`) or visible in `device_screenshot`.
- For "start/play": the screen shows it running, not just its launcher.
- Your reply says exactly what you saw, nothing more.
