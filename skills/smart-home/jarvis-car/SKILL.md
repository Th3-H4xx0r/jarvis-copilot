---
name: jarvis-car
description: Check, lock, unlock and start the car.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Car, Toyota, Wearables, CarPlay, Dashcam]
    category: smart-home
    related_skills: [jarvis-dashcam, jarvis-wearables]
---

# Car Skill

Pranav's car — a 2026 Toyota Camry SE in Dark Cosmos — is a Jarvis wearable on the iPhone. Other
wearables are **linked** to it (the dashcam today, the car lights later), and the car gathers
their **controls** in one place: on its phone page, in CarPlay, and as the `car_set_control`
skill here. The car itself — range, fuel, locks, tyres, health, where it's parked, remote start,
climate — comes from Toyota's cloud through his Home Assistant's Toyota integration, as the
`toyota_*` tools; those work from anywhere, even while the phone is asleep. The dashcam keeps its
own `dashcam_*` skills (see `jarvis-dashcam`).

## When to Use

- "Am I in the car?", "When was I last in the car?", "What's linked to my car?"
- "Turn on the car lights", "Set the car lights to 40 %" — once lights are linked.
- Before a dashcam question, when you need to know whether the phone is with the car.
- "Is my car locked?", "How much range is left?", "Where did I park?", "Tyre pressures?" — `toyota_status`.
- "Lock the car", "Start the car", "Unlock the trunk", "Flash the hazards", "Honk" — `toyota_command`.
- "Start the car at 70 with the defroster" — `toyota_climate` set, then `toyota_command start`.

## Prerequisites

- `car_*`: the JarvisCopilot iPhone app paired with this server, with the car shared with Jarvis
  (on by default). They arrive as ordinary device skills from the phone.
- `toyota_*`: `HASS_URL` / `HASS_TOKEN` on the server, and Pranav signed in with Toyota on the
  iPhone Car page (Toyota account card). Remote commands need his Toyota Remote Connect plan.

## How to Run

Call the phone's `car_*` device skills and the server's `toyota_*` tools directly.

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `car_get_status` | — | Car profile, `in_car` + `last_seen`, linked devices with status, controls with values. |
| `car_set_control` | `control` (id), `value` (string) | Use one control. Only present while the car has controls. |
| `toyota_status` | `refresh?` | Range, fuel, odometer, locks/doors/windows/trunk, tyres, health, location, remote-started, last report. |
| `toyota_command` | `command`, `confirmed?` | `start stop lock unlock trunk_lock trunk_unlock lights horn buzzer hazards_on hazards_off`. |
| `toyota_climate` | `action` get/set, `custom?`, `temp?`, `defrost_front?`, `defrost_rear?` | The climate used at remote start. |

Values by control kind: toggle `on`/`off`, level a number (clamped and snapped to its step),
choice an option id, button no value.

## Procedure

1. Run `car_get_status` first: it lists the controls by id with their kind and current value.
2. To change one, call `car_set_control` with that id and a value of the right kind.
3. For the dashcam (clips, recording, sync), use the `dashcam_*` skills.
4. **Unlock, trunk_unlock and start need his yes.** Call `toyota_command` without `confirmed`; it
   sends nothing and returns a question ("Unlock the car?"). Ask him, and only after he says yes
   call again with `confirmed: true`. Everything else runs at once.

## Pitfalls

- `car_set_control` is missing while no linked device adds a control — that is normal, not
  an outage. Say the car has no controls yet.
- `in_car` is true while Jarvis is on CarPlay, audio goes to the car, or the phone is on the
  dashcam's Wi-Fi; otherwise read `last_seen`.
- A bad value is refused with the accepted range or options — retry with one of those.
- `toyota_status` shows the last data the car sent (`updated_at`); `refresh: true` wakes the car,
  which is slow and uses its battery — only when he asks for fresh data.
- Never repeat a car command on your own (a second horn, a second start). Report the error.
- "Sign in with Toyota on the Car page first" means exactly that — you can't sign in for him.

## Verification

`car_get_status` returns `"car": {"model": "Camry", ...}`; after `car_set_control`, the result's
`control.value` shows the new value. `toyota_command` returns `"result": "Locked"` (or the
question to ask); a later `toyota_status` shows the new lock state.
