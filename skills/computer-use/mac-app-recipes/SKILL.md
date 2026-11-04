---
name: mac-app-recipes
description: "Fast known routes for Pranav's Mac apps and settings."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [mac, apps, messages, spotify, notes, settings, meetings, computer-use]
    related_skills: [mac-control, mac-screen-look, mac-dev-setup]
---

# Mac App Recipes Skill

Known-good, fastest routes for the apps and settings Pranav uses on his
MacBook. Each recipe goes through the app's own tool or a shell command before
any clicking; clicking (`computer_do`) is the fallback. Follow `mac-control`
for the general rules (device argument, preflight, verify before "done").

## When to Use

- He wants something done in a specific Mac app: Messages, Spotify, Notes,
  Reminders, Brave/Chrome, Teams/Meet/Zoom, Discord, Finder, System Settings.
- Battery, volume, Low Power Mode, Wi-Fi/Bluetooth, Focus, lock.

## Prerequisites

- Mac online. Pass `device` with the Mac's exact name to every `device_*` call.
- `device_run_shell` is enabled on his Mac.
- First use of `osascript` against an app can pop a macOS "allow control"
  prompt on his screen. If the result has error `-1743`, tell him to click
  Allow on the Mac (or in System Settings → Privacy → Automation).

## How to Run

Pick the recipe, run it, then check the result with the read in the last column.

| Task | Route | Check |
|---|---|---|
| Text someone | `device_messages_send {to, text}` (or `group`) | result `ok`; say "sent via Messages" |
| Play music on the Mac | `spotify_search` → `device_spotify_play {uri}` | result says playing |
| Pause / next / prev | `device_media_control {action}` | result state |
| Spotify on another device | `spotify_devices` → `spotify_playback` with `device_id` | `spotify_playback` state |
| Volume | `device_volume_set {level}` | `device_volume_get` |
| Battery | `device_run_shell {cmd: "pmset -g batt"}` | (it's the read) |
| Low Power Mode | open Battery settings: `device_run_shell {cmd: "open 'x-apple.systempreferences:com.apple.Battery-Settings.extension'"}` → `computer_do` toggle "Low Power Mode" in System Settings | `pmset -g \| grep lowpowermode` |
| Wi-Fi on | `device_run_shell {cmd: "networksetup -setairportpower en0 on"}` | `networksetup -getairportpower en0` |
| Bluetooth / Focus / Dark Mode | `computer_do` in Control Center (`app: "Control Center"`), or a Mac Shortcut if `shortcuts list` shows one made for it | re-open Control Center with `device_ui_look` |
| Lock the Mac | `device_lock_screen` | lock check (`ioreg -n Root -d1 \| grep -c CGSSessionScreenIsLocked` → 1) |
| Open a page in a given browser | `device_run_shell {cmd: "open -a 'Brave Browser' '<url>'"}` | `device_current_window` title |
| New note | `device_run_shell {cmd: "osascript -e 'tell application \"Notes\" to make new note with properties {name:\"<title>\", body:\"<text>\"}'"}` | `osascript -e 'tell application "Notes" to get name of note 1'` |
| Reminder | `osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<text>"}'` | `osascript -e 'tell application "Reminders" to get name of reminders whose completed is false'` |
| Join a meeting | find the link (email via `himalaya` skill, calendar via `google-workspace`) → `device_open_url {url}` | `device_current_window` shows Meet/Teams/Zoom |
| Open a file/folder | `device_run_shell {cmd: "open '<path>'"}`; find with `mdfind -name '<name>' \| head` | window title |
| Quit an app | `device_quit_app {name}` | `device_list_windows` |

## Quick Reference

- App names he means: "Brave" = `Brave Browser`, "Chrome" = `Google Chrome`,
  "VS Code" = `Visual Studio Code`, "Teams" = `Microsoft Teams`.
- Voice mishearings: "braid" = Brave, "spot a fly" = Spotify. Fix them before calling.
- URL schemes skip clicking:
  - Spotify: `spotify:`
  - Messages: `sms:`
  - Mail: `mailto:`
  - Settings panes: `x-apple.systempreferences:…`
  - Meet/Zoom/Teams links open their apps.
- Todos: ask which app he uses once (Reminders, Notes, or the Jarvis todo-list
  skill) and remember it. Never fall back to TextEdit.

## Procedure

1. Find the recipe row. If none fits, use `mac-control` with `computer_do`, giving
   `app` and exact `steps`.
2. Run the route. If the first route fails, use the next one: shell, then
   `computer_do` in that app. Don't retry the same call.
3. Run the row's check. Report what the check shows ("Low Power Mode is now on",
   "Spotify is playing Blinding Lights on the Mac").
4. For anything sent to another person (Messages, email), the ask-before-sending
   rule applies: confirm with him first unless he dictated the exact text and
   recipient in this turn.

## Pitfalls

- Messages: phone numbers need the country code if the contact lookup fails. For
  groups, pass `group` with part of the group's name.
- Spotify GUI search fields are unreliable to click (it "did nothing three
  times"). Always search through `spotify_search` and play by URI.
- System Settings toggles that need an admin password can't be finished by you.
  Say so.
- Opening the "Health" app or "Screenshot" app because a word matched is wrong.
  Health data comes from the iPhone, and screenshots from `mac-screen-look`.
- Never turn Wi-Fi off or change network settings on the Mac. That cuts the Mac
  off from Jarvis, and nothing can turn it back on remotely.
- Don't change Focus or Bluetooth unless he asked.

## Verification

- Every recipe's check ran and its output is what the reply states.
- The reply names the app and device ("on your MacBook in Brave").
