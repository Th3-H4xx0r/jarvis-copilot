---
name: jarvis-car
description: Check the car and use its controls through the phone.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Car, Wearables, CarPlay, Dashcam]
    category: smart-home
    related_skills: [jarvis-dashcam, jarvis-wearables]
---

# Car Skill

Pranav's car — a 2026 Toyota Camry SE in Dark Cosmos — is a Jarvis wearable on the iPhone. Other
wearables are **linked** to it (the dashcam today, the car lights later), and the car gathers
their **controls** in one place: on its phone page, in CarPlay, and as the `car_set_control`
skill here. This skill reads the car and uses those controls; the dashcam keeps its own
`dashcam_*` skills (see `jarvis-dashcam`). It does not unlock, start or locate the car.

## When to Use

- "Am I in the car?", "When was I last in the car?", "What's linked to my car?"
- "Turn on the car lights", "Set the car lights to 40 %" — once lights are linked.
- Before a dashcam question, when you need to know whether the phone is with the car.

## Prerequisites

The JarvisCopilot iPhone app paired with this server, with the car shared with Jarvis
(on by default). The skills arrive as ordinary device skills from the phone.

## How to Run

Call the device skills directly, like any phone device skill.

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `car_get_status` | — | Car profile, `in_car` + `last_seen`, linked devices with status, controls with values. |
| `car_set_control` | `control` (id), `value` (string) | Use one control. Only present while the car has controls. |

Values by control kind: toggle `on`/`off`, level a number (clamped and snapped to its step),
choice an option id, button no value.

## Procedure

1. Run `car_get_status` first: it lists the controls by id with their kind and current value.
2. To change one, call `car_set_control` with that id and a value of the right kind.
3. For the dashcam (clips, recording, sync), use the `dashcam_*` skills.

## Pitfalls

- `car_set_control` is missing while no linked device adds a control — that is normal, not
  an outage. Say the car has no controls yet.
- `in_car` is true while Jarvis is on CarPlay, audio goes to the car, or the phone is on the
  dashcam's Wi-Fi; otherwise read `last_seen`.
- A bad value is refused with the accepted range or options — retry with one of those.

## Verification

`car_get_status` returns `"car": {"model": "Camry", ...}`; after `car_set_control`, the result's
`control.value` shows the new value.
