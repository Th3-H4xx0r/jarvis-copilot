---
name: pc-color-control
description: Set the gaming PC's fan, cooler and strip lighting.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, PC, RGB, Lights, OpenRGB, Gaming]
    category: smart-home
    related_skills: [jarvis-car-lights, openhue]
---

# PC Color Control Skill

Colours Pranav's gaming PC (top, rear and bottom fans, the cooler's logo, the bottom strip) part by
part or all at once, with effects, speed, brightness and saved looks, and helps with setup and
calibration tests. It goes through the PC Lighting tools, the same server routes the iPhone and the
web use. It never writes the LED map (calibration is finished on the iPhone) and controls nothing
else on the PC.

## When to Use

- "Make my PC red", "PC lights off", "dim the PC to 30 %".
- "Rainbow on the fans, white strip", "make the comet faster", "breathing purple".
- "Save this as Gaming", "put on my Late night look".
- "What colour is my PC?", "why aren't my PC lights changing?"
- "Set up the PC lighting", "is OpenRGB working?", "light LEDs 10–20 on that header".
- "What motherboard / GPU is in my PC?"

## Prerequisites

- The PC Lighting Power integration on (Integrations tab). Off, every call answers
  "PC Lighting is switched off".
- The PC awake and connected to Jarvis, with OpenRGB running on it (setup steps `openrgb`, `detect`).
- Calibration finished on the iPhone (Devices → Wearables → PC), so each part has LEDs.

His PC: ASRock B760M-C, lights driven by OpenRGB. All 7 fans hang off one ARGB hub that mirrors a
single stream, so the top, rear and bottom fans always show the same colour and effect. The strip and
the cooler logo are chained on another connector: they can differ from the fans and from each other.

## How to Run

Call the native tools `pc_lights`, `pc_light_looks` and `pc_light_setup` with an `action`. Each
answers JSON with `ok`; on failure `error` says why, plus `offline: true` (PC asleep) or
`engine_error: true` (OpenRGB down). Changes are validated by the server, which pushes them to the PC.

## Quick Reference

| Tool | Action | Arguments | Does |
|---|---|---|---|
| `pc_lights` | status | — | on, brightness, each part's effect/colour/speed and `lights` (own, mirrors X, none), online, engine, paused_for_game, setup progress |
| `pc_lights` | on / off | — | the whole PC |
| `pc_lights` | brightness | `brightness` 0–100 | the whole PC (there is no per-part brightness) |
| `pc_lights` | color | `color`, `part` | one part or all |
| `pc_lights` | effect | `effect`, `speed` (optional), `part` | one part or all |
| `pc_lights` | speed | `speed` 1–10, `part` | animated effects only |
| `pc_lights` | set | `part` + any of `color`, `effect`, `speed`, `brightness`, `on` | several changes in one call |
| `pc_light_looks` | list / save / apply / delete | `name` | saved looks; apply also turns the lights on |
| `pc_light_setup` | steps / run_step | `step` | the setup checklist; start one step |
| `pc_light_setup` | connectors | — | OpenRGB controllers, zones, LED counts, parts mapped on each |
| `pc_light_setup` | test_leds | `controller`, `zone`, `start`, `count`, `color` | light LEDs start…start+count−1, everything else dark |
| `pc_light_setup` | led_count | `controller`, `zone`, `count` | set a resizable zone's LED count and light them all |
| `pc_light_setup` | clear_test | — | back to the normal lighting |
| `pc_light_setup` | map | — | the LED map and coverage (read-only) |
| `pc_light_setup` | specs / refresh_specs | — | the PC's hardware; refresh reads it from the PC now |

Parts: `top`, `rear`, `bottom` (fans), `cooler` (logo), `strip`, `all` (the default).

| Effect | Looks like | Uses the colour | Speed 1 → 10 (5 is the default) |
|---|---|---|---|
| static | solid colour | yes | — |
| breathing | fades between 15 % and full | yes | one breath every 10 s → 1 s |
| comet | a bright head with a fading tail runs round | yes | one lap every 8 s → 0.8 s |
| rainbow | a rainbow wave travels along the LEDs | no | one cycle every 20 s → 2 s |
| spectrum | the whole part fades through every colour together | no | one cycle every 40 s → 4 s |

Colours: send a name or `#rrggbb`. The PC turns screen colours into LED power, so the tool's
colour names are LED colours (each has a channel at full; a dark hex looks dim on the fans). Names
and what they send:

| He says | Send |
|---|---|
| red | #ff0000 |
| orange | #ff6a00 |
| yellow | #ffff00 |
| gold, amber | #ffbf00 |
| green, lime | #00ff00 |
| teal, mint | #00ffc0 |
| cyan, aqua | #00ffff |
| sky blue | #00aaff |
| blue | #0000ff |
| purple | #8000ff |
| violet, lavender | #b266ff |
| magenta | #ff00ff |
| pink, deep pink | #ff1493 |
| hot pink | #ff69b4 |
| white | #ffffff |
| warm white | #ffd7a8 |
| cool white | #e6f0ff |
| one part dark | #000000 |

For the whole PC dark, use `off` instead of black.

## Procedure

1. Unsure what's on, or why something failed: `pc_lights` status first.
2. One control asked for: its own action (color, effect, speed, brightness, on, off). Several at
   once ("breathing red, slow"): one `set` call (`effect` breathing, `color` #ff0000, `speed` 2).
3. "The PC" or "everything": `part` all. "The fans": any one fan part; the server also sets the part
   that owns the fans' LEDs. Never promise different colours on top, rear and bottom fans: they
   are one stream. Offer fans vs cooler logo vs strip instead.
4. "Brighter"/"dimmer" without a number: read status, then move brightness by about 25.
5. Looks: `save` stores the current lighting (same name replaces it); `apply` restores one and turns
   the lights on; `list` before guessing a name.
6. Answer in one short line from the returned `state`. If the reply has a `note` (a mirrored part's
   owner changed too, or a game is pausing effects), say it.

Setup and calibration:

1. `pc_light_setup` steps shows the checklist (todo, running, done, skipped, failed + detail).
2. `run_step` in order: openrgb, signalrgb, driver, detect, cost. Each runs in the background;
   read steps again after a few seconds. openrgb, signalrgb and driver ask Face ID on his iPhone
   before installing or stopping anything: tell him to look for it. Steps never run during a game.
3. The calibrate step is his, on the iPhone: send him there, never claim it's done.
4. Calibration help: `connectors` lists what OpenRGB sees; `test_leds` lights a range in a bright
   colour so he can say which part lit ("controller 0 zone 1, LEDs 0–15, red"). For a strip's length,
   `led_count` up or down until the last lit LED is the strip's end. Always `clear_test` when done.
5. Specs: `specs`; if empty or old, `refresh_specs` (the PC must be awake).

## Pitfalls

- "The PC is asleep or offline" (`offline: true`): nothing changed and nothing is queued. Say so.
- `engine_error: true` or status engine "error": OpenRGB isn't answering. Run `run_step` openrgb
  (it restarts or reinstalls OpenRGB), then detect; if SignalRGB grabbed the lights, run signalrgb.
  Don't retry the colour in a loop.
- "has no lights mapped" or "isn't set up yet": that part (or the whole map) isn't calibrated:
  send him to the iPhone.
- `paused_for_game`: animated effects freeze while a game runs (the cost step chose this); colours
  still change and effects resume afterwards.
- Status `push_error`: the PC didn't take the last change (e.g. "Update Jarvis on the PC").
- Brightness 0 is dark but still "on"; for "lights off" use off, and on brings them back.
- rainbow and spectrum ignore the colour; static, breathing and comet use it.
- Test lighting blanks every other light and pauses the effects until `clear_test`.

## Verification

- A change returns `ok: true` and the new `state`. The PC is told right after the reply, so a
  follow-up status with online true, engine "running" and no `push_error` means it landed.
- Setup: steps shows each step's state and detail.
- test_leds returns `ok: true`; ask him what lit up.
