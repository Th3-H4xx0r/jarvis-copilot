---
name: jarvis-car-lights
description: Control the car's LED ambient lights through the phone.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Car, Lights, LED, Bluetooth, Music]
    category: smart-home
    related_skills: [jarvis-car, jarvis-dashcam]
---

# Car Lights Skill

The car's ambient LED kit is a Magic Lantern ("MELK-…") Bluetooth controller that the iPhone app
drives directly. It is linked to the car, so its power, brightness, colour and effect are also car
controls (`car_set_control`). This skill does everything the Magic Lantern app does: colour, white
and colour temperature, brightness, 213 effects and their speed, scenes, music from the lights' own
microphone or the phone's, two weekly timers, and the wiring settings. The lights have no zones:
every lamp always shows the same thing, so there is no per-lamp control.

## When to Use

- "Turn the car lights blue", "dim the car lights", "lights off".
- "Put the car lights on a rainbow / strobe / 7-colour jump", "make it faster".
- "Make the lights dance to the music" (the lights' own mic is best in the car).
- "Turn the car lights on at 6 pm on weekdays".

## Prerequisites

The JarvisCopilot iPhone app with the lights paired (Car → Car lights → Add lights). The lights
must be connected — the car on and the phone near it; otherwise every change is refused as
unavailable (nothing is queued for later).

## How to Run

Call the phone's device skills directly.

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `lights_get_status` | — | Controllers, link, last-set state, what each can do, lamps per controller. |
| `lights_set` | `target`, `power`, `color`, `brightness`, `white`, `temperature`, `effect`, `speed`, `scene`, `music`, `mic_effect`, `sensitivity` | Any combination of changes. |
| `lights_list_effects` | — | The 213 effects by group, 28 scenes, 8 mic effects. |
| `lights_timer` | `target`, `timer` (on/off), `time` HH:MM, `days`, `enabled` | Set a timer, or read both back when only `target` is given. |
| `lights_setup` | `target`, `pin_order`, `led_count` | Wiring: colour order and LED count (set once). |

`target` is optional: all lights, or a controller's name.

## Procedure

1. Run `lights_get_status` if unsure what is paired or what a controller can do.
2. Send one `lights_set` with every change at once (e.g. `color` + `brightness`).
3. For an effect by name, use the name from `lights_list_effects` (or its id).
4. For music in the car, prefer `music: "lights_mic"`; `phone_mic` uses the phone's microphone.

## Pitfalls

- The lights never report their state; `lights_get_status` shows what was last sent.
- "aren't connected" means the car is off or the phone is away: say so, don't retry.
- `scene` works only on OC/OT controllers, `white` on W units, `temperature` on CT units.
- A wrong colour order (red shows green) is fixed with `lights_setup` `pin_order`, not a colour.

## Verification

`lights_set` returns the controllers' new state; `connected: true` means it reached the lights now.
