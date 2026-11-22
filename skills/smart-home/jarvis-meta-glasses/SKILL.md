---
name: jarvis-meta-glasses
description: Control Ray-Ban Meta glasses through the phone.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Wearables, Glasses, Camera, Vision, Voice]
    category: smart-home
    related_skills: [jarvis-wearables, jarvis-ring]
---

# Meta Glasses Skill

The wearer's **Ray-Ban Meta (Gen 2) Scriber Optics** glasses: a 12 MP camera (photos, clips,
live view), open-ear speakers, mics with the on-glasses "Hey Jarvis" wake word, and a touchpad.
The Jarvis iOS app holds their link and advertises them as `meta_glasses_*` device skills. Those
are the same skills, with the same results and refusals, whether the real glasses or the app's
hardware simulator is selected, so treat them as the glasses. This skill does not pair the
glasses, change their owner or bypass the capture LED.

## When to Use

- "What am I looking at?", "read this", "what does that sign say": anything about what the wearer
  sees right now.
- Take a photo or record a clip with the glasses; show or import what they captured.
- Say something through the glasses, change their volume, start/stop the live view.
- Battery, storage, heat, whether they're worn; clip length or video mode.

## Prerequisites

- The Jarvis iOS app paired with this server and reachable, with Meta glasses on in the app
  (Devices → Wearables → Meta glasses). In a conversation the skills are already tools:
  `device_meta_glasses_photo`, `device_meta_glasses_status` and so on.
- For scripts: the bundled `jarviscopilot/devices` skill (its `devices.py` signs requests to the
  web UI). `scripts/meta_glasses.py` finds it next to this skill, then under
  `$JARVISCOPILOT_DIR/skills`, `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.

## How to Run

Call the device tools directly. From a script or cron job, run `scripts/meta_glasses.py` with
`terminal` (stdlib only, Python 3.10+); it prints the skill's JSON, or `{"error": ...}` on
stderr with exit code 1:

```bash
MG="$HERMES_HOME/skills/smart-home/jarvis-meta-glasses/scripts/meta_glasses.py"
python3 "$MG" status
python3 "$MG" photo --question "What am I looking at?"
python3 "$MG" video --seconds 30
python3 "$MG" media latest-photo
python3 "$MG" speak "Your 3 o'clock is in five minutes"
python3 "$MG" settings --clip-length 60 --video-mode 1080p60
```

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `meta_glasses_status` | — | `battery_percent`, `charging`, `worn`, `folded`, `in_case`, `in_range`, `heat`, `camera_unavailable_because`, `storage_free_gb`, `photos_on_glasses`, `videos_on_glasses`, `streaming`, `recording_seconds`, `volume`, `video_mode`, `clip_length_seconds`. |
| `meta_glasses_photo` | `question`, `confirm: true` | A still from the glasses camera (what the wearer sees), returned as an image for vision; the full 12 MP stays on the glasses. |
| `meta_glasses_look` | — | Whether the camera can capture now and why not; while live streaming, the current frame as an image. |
| `meta_glasses_video` | `action`: `record` (default) \| `start` \| `stop` \| `toggle`; `seconds` (1–180); `confirm: true` to start | `record` waits for an N-second clip; `start` returns at once and records until `stop` or the clip length; `toggle` starts or stops (one ring button). Capped by the clip length setting; `stopped_early` says why one ended early. |
| `meta_glasses_live` | `action`: `start` \| `stop` | Live view to the phone (≤720×1280 @30); the phone joins the glasses' Wi-Fi meanwhile. |
| `meta_glasses_media` | `action`: `list` \| `latest_photo` \| `import`; `question` | What's on the glasses / phone; the newest photo as an image; import everything to the phone's Photos. |
| `meta_glasses_speak` | `text` | Says it through the open-ear speakers. |
| `meta_glasses_volume` | `level` 0–100 | Speaker volume. |
| `meta_glasses_talk` | — | Opens the glasses' assistant (chime, listens) so the wearer can ask. |
| `meta_glasses_settings` | `clip_length_seconds` (30/60/180), `video_mode` (`3k30`, `1080p30`, `1080p60`, `720p120`) | Reads or changes capture settings. |

Hardware limits the glasses enforce (and refuse with their own reason): 12 MP 3024×4032 photos;
clips 30 s default, 3 min max; 32 GB storage; ~8 h battery (the case adds ~48 h); the camera is
off when the capture LED is covered, when they're too hot, folded, in the case, out of range or
below 10 % battery; the wake word and assistant need them worn.

## Procedure

1. **"What am I looking at?"**: `meta_glasses_photo` with `confirm: true` and the wearer's
   question as `question`, then answer from the image. If they're live streaming,
   `meta_glasses_look` gives the current frame without a new capture.
2. **A refusal is the glasses talking.** Relay the reason plainly ("the capture LED is covered",
   "they're folded", "battery is at 8 %") and what fixes it; don't retry blindly.
3. **Clips:** `meta_glasses_video` with `seconds` for a fixed clip; `action: start` / `stop`
   for "start recording … stop"; report `seconds`, `mode` and any `stopped_early`. For longer
   clips raise `clip_length_seconds` first (max 180).
4. **Their captures:** `meta_glasses_media` `list` to see what's there, `latest_photo` to look at
   the last shot, `import` to move everything to the phone's Photos.
5. **Speaking to the wearer:** `meta_glasses_speak` for short notices; keep it to a sentence.
6. **Before heavy capture** (long 3K clips, live view), check `meta_glasses_status` for battery
   and heat.

## Pitfalls

- **`confirm: true` is required** for `meta_glasses_photo` and `meta_glasses_video`. It's the
  owner's rule for the camera. Only pass it when the wearer asked for a photo or clip (or asked
  what they're looking at).
- **The capture LED always lights and can't be hidden.** Never suggest covering or disabling it;
  a covered LED blocks the camera.
- **Don't identify people** from the glasses' photos or video (faces or voices).
- **Live view moves the phone onto the glasses' Wi-Fi**, so stop it when done
  (`meta_glasses_live` `stop`).
- **3K recording heats the glasses.** About 15 minutes of it turns the camera off until they cool
  (3–5 min).
- **Don't gate on `bridge_connected`.** A backgrounded phone still runs skills after a silent push.

## Verification

- `meta_glasses_status` returns `model: "Ray-Ban Meta (Gen 2)"` and `battery_percent`.
- `meta_glasses_photo` with `confirm: true` returns `mime: "image/jpeg"` and an image the
  vision step can read.
- After `meta_glasses_media` `import`, `saved_to_photos` matches what appears in Photos.
- `python3 scripts/meta_glasses.py status` exits 0 and prints JSON.
