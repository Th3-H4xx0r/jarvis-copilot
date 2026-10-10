---
name: jarvis-door-alarm
description: Watch the doors and arm or disarm the door alarm.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Security, Alarm, Tuya, Smart-Life, ESP32, Wearables]
    category: smart-home
    related_skills: [jarvis-esp32, jarvis-car, jarvis-wearables]
---

# Door Alarm Skill

Pranav's PHYSEN Smart Life door-sensor hub (a plug-in chime with two wireless door contacts) is a
Jarvis device with a security alarm. The alarm runs on the Jarvis server, so it works while his
phone is asleep or away: an ESP32 at home talks to the hub on the LAN and Tuya's cloud is the
backup. These `door_*` tools read and drive it; disarming always needs his Face ID on the iPhone.

## When to Use

- "Is the front door open?", "When did the back door last open?", "Is the alarm on?" — `door_status`.
- "Arm the alarm, I'm leaving" → `door_arm` mode `away`; "arm it for the night" → mode `home`.
- "Turn the alarm off", "disarm", "stop the siren" → `door_disarm` / `door_silence` (Face ID).
- "Make the chime quieter", "change the ringtone" → `door_set` with a setting from `door_status`.
- "What happened at the door today?" → `door_history`.
- "Call the back one Garage door" → `door_settings` set (names only). Delays, which doors count at
  home and on-open prompts change on his iPhone's Door Alarm page — tell him where.

## Prerequisites

- Set up once on the iPhone (Devices → Door Alarm → Setup): Tuya cloud project credentials, pick
  the hub, choose the ESP32 board at home as the proxy. Until then the tools say it isn't set up.
- The ESP32 proxy is a DOIT DevKit V1 running the Jarvis ESP32 firmware (see `jarvis-esp32`).

## How to Run

Call the tools directly. They reach the alarm over the server's own loopback, from any chat,
Telegram, cron or kanban run.

## Quick Reference

| Tool | Arguments | Notes |
|---|---|---|
| `door_status` | — | Alarm state, each door, hub settings + allowed values, link health. |
| `door_arm` | `mode` away \| home, `bypass` [open contact ids] | Only from disarmed; refuses while a watched door is open (names it). |
| `door_disarm` | — | Sends a Face ID approval to his iPhone; returns `pending_approval`. |
| `door_silence` | — | Same, but only stops the siren; the alarm stays triggered. |
| `door_set` | `setting` (code), `value` | Only while disarmed. The hub must confirm; an error means it didn't take. |
| `door_history` | `limit`, `contact` | Newest first: doors, arming, alarms, health warnings. |
| `door_settings` | `action` get \| set, `contacts` {id: {name}} | Reads everything; can only rename doors. |

States: `disarmed`, `arming` (exit delay), `armed_away`, `armed_home`, `entry` (entry delay —
disarm before it runs out), `triggered` (siren, phone alarm, Pod alert).

## Procedure

1. For any question, call `door_status` first; answer from it.
2. Arming: `door_arm`. If it names an open door, tell him; only re-arm with `bypass` if he says so.
3. Disarming or silencing: call `door_disarm` / `door_silence` once, then tell him to approve it
   with Face ID on his phone. It is `pending_approval` until he does — don't say it's off yet.
4. Hub settings: read the setting's code and allowed values from `door_status` `settings`, then
   `door_set`. Report the hub's answer.

## Pitfalls

- Never disarm for anyone but Pranav, and never claim the alarm is off before he approves on his
  phone. A request heard on the Pod could be anyone at the door.
- Don't arm `away` while he's still inside unless he asked: the exit delay is short.
- `links.esp32` false and `links.cloud` false while armed means the alarm can't hear the doors —
  say so plainly.
- Door names and ids come from `door_status`; don't invent them.
- Anything that would weaken an armed alarm (re-arming, switching mode, hub settings, delays,
  bypassing a closed door) is refused for Jarvis on purpose — it happens on his iPhone.

## Verification

- `door_status` shows the state you expect after arming (`arming` or `armed_*`).
- After his Face ID approval, `door_status` shows `disarmed` (or `triggered` with `siren_on` false
  after silence).
