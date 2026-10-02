---
name: jarvis-dashcam
description: Find dashcam clips and drives and control the camera.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Car, Dashcam, GPS, Video, Google-Drive, Backup]
    category: smart-home
    related_skills: [jarvis-x5-ring, jarvis-ring]
---

# Dashcam Skill

The Affver A4 dashcam (Viidure/Peztio family) is a Jarvis device. The iPhone joins the
camera's Wi-Fi on its own, pulls each clip's GPS track, thumbnail and footage by the sync
rules, and uploads it through the Jarvis server to Google Drive and SFTP/FTP/SMB. This skill
reads the server's clip index (clips, drives, where and how fast the car was at a time, trip
stats, GPX) and drives the camera through the phone's `dashcam_*` device skills. It does not
update firmware, show live video, or reach the camera without the phone.

## When to Use

- "Where was I at 3:40?", "How fast was I going on the highway?", "How much did I drive this
  week?", "Show me yesterday's drives."
- "Save that" / "save this moment" while driving: lock the current clip.
- Finding or re-sending clips: events from today, clips still waiting to upload, failed uploads.
- Changing camera settings, recording on/off, SD card space, the camera's Wi-Fi.
- Adding or checking an upload destination (Google Drive, a NAS over SFTP/SMB, an FTP server).

## Prerequisites

- The Jarvis iOS app paired with this server, with the dashcam set up in Devices (Wi-Fi name
  and password). Device skills need the phone near the camera, on its Wi-Fi; the server
  commands work any time.
- In a Jarvis conversation the device skills are tools: `device_dashcam_get_status`,
  `device_dashcam_lock_clip` and so on, with an optional `device` argument to pick the phone.
- For scripts: the bundled `jarviscopilot/devices` skill (host-signed web UI client).
  `scripts/dashcam.py` finds it next to this skill, then under `$JARVISCOPILOT_DIR/skills`,
  `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.
- Uploads need rclone on the server: `scripts/install-rclone.sh` in the repo (pinned version).
- Google Drive: run `scripts/connect_drive.sh` on a Mac with rclone (`brew install rclone`).
  It signs in through the browser there and sends the token to the server.

## How to Run

Run `scripts/dashcam.py` with `terminal` (stdlib only, Python 3.10+). It prints JSON, or
`{"error": ...}` on stderr with exit code 1. Always pass times with a UTC offset; a time
without one is read in the server's local time zone.

```bash
DC="$HERMES_HOME/skills/smart-home/jarvis-dashcam/scripts/dashcam.py"
python3 "$DC" where --at 2026-10-01T15:40:00-05:00
python3 "$DC" stats --days 7
python3 "$DC" clips --kind event --from 2026-10-01T00:00:00-05:00
python3 "$DC" clips --state failed
python3 "$DC" lock
python3 "$DC" settings set speed_unit mph
printf '%s\n' "$NAS_PASSWORD" | python3 "$DC" add-destination --type sftp --name NAS \
    --host nas.local --user pranav --path /volume1/dashcam --password-stdin
```

In Python: `from dashcam import Dashcam, DashcamError` — one method per command.

## Quick Reference

Server commands (the clip index; no phone needed):

| Command | What it returns |
|---|---|
| `status` | Cameras, sync rules, destinations, clip counts, staging bytes/cap, `relay.installed`. |
| `clips [--kind --lens --state --from --to --drive --limit]` | Clips newest first + `next` cursor. States: `on_camera_only`, `on_phone`, `uploading`, `uploaded`, `failed`, `pending_upload`. |
| `clip <id>` / `retry <id>` | One clip with GPS fixes and per-destination status / re-queue its failed uploads. |
| `drives [--days 7]` / `drive <id>` | Drives with `miles`, `avg_mph`, `max_mph`, `minutes` / one drive with its route. |
| `where --at T` / `speed --at T` | Nearest GPS fix within 120 s: lat/lon, `speed_mph`, heading, clip, map link. |
| `stats [--days 7]` | Drives, miles, hours, driving hours, top and average mph. |
| `gpx <drive> [-o file]` | The drive as GPX 1.1. |
| `destinations` / `add-destination` / `test-destination <id>` / `delete-destination <id>` | Upload targets: `drive`, `sftp`, `ftp`, `smb`. |

Device skills (the phone on the camera's Wi-Fi; they stay listed while the camera is away and
then answer "not connected to the dashcam's Wi-Fi"):

| Skill | Arguments | CLI |
|---|---|---|
| `dashcam_get_status` | — | `camera-status` |
| `dashcam_sync` | `resync` | `sync [--resync]` |
| `dashcam_lock_clip` | — | `lock` |
| `dashcam_snapshot` | `lens` | `snapshot [--lens rear]` (photo returned as a file) |
| `dashcam_set_recording` | `enabled` | `record on\|off` |
| `dashcam_get_settings` | — | `settings` (values + allowed options) |
| `dashcam_set_setting` | `key`, `value` | `settings set <key> <value>` |
| `dashcam_sd_info` | — | `sd` |
| `dashcam_format_sd` | `confirm: true` | `format-sd --confirm` |
| `dashcam_delete_file` | `path`, `confirm: true` | `delete-file <path> --confirm` |
| `dashcam_set_wifi` | `ssid`, `password` | `wifi --ssid NAME --password-stdin` |
| `dashcam_fetch_range` | `from`, `to` (ISO) | `fetch --from T --to T` |

Units: the server stores metres and m/s; the CLI adds miles and mph. Times are UTC in replies.

## Procedure

1. **Where / how fast:** `where --at` with the user's time and offset. `offset_s` says how far
   the fix is from the asked time; answer with `speed_mph` and the map link.
2. **Trips:** `drives --days N` for a list, `stats --days N` for totals. A drive is clips less
   than 5 minutes apart; parking and photo clips are never drives.
3. **Saving a moment:** `dashcam_lock_clip` right away (the camera locks the clip it is
   recording); it uploads on the next sync as an event.
4. **Missing uploads:** `clips --state failed` → `clip <id>` shows each destination's error →
   fix the destination (`test-destination`) → `retry <id>`.
5. **A clip from a time range:** `fetch --from --to` queues it on the phone; it shows in
   `clips` as `on_phone`, then `uploaded`.
6. **New destination:** SFTP/FTP/SMB with `add-destination` (password on stdin), then
   `test-destination`. Google Drive with `scripts/connect_drive.sh --ssh <server>` on the Mac.

## Pitfalls

- **Device skills need the phone on the camera's Wi-Fi.** Away, they fail fast; don't retry in
  a loop — sync happens by itself the next time the phone joins.
- **`dashcam_format_sd` and `dashcam_delete_file` erase footage on the camera.** Only with the
  user's explicit go-ahead in this conversation, and always with `confirm`.
- **A clip still being recorded grows** between listings; it isn't uploaded until its size is
  stable, so the newest clip lags by a minute or two.
- **Never put passwords or tokens on the command line.** Use `--password-stdin` or
  `--json-stdin`; the server stores them only in rclone's config and never returns them.
- **Google Drive tokens come from a browser sign-in on a Mac**, not from the server. rclone's
  shared Drive client id is being retired; pass your own `--client-id/--client-secret` to
  `connect_drive.sh` if Drive uploads start failing with quota or auth errors.
- **`where` needs GPS.** Clips from a garage or before the first fix have none; the answer is
  "no GPS fix within 120 s".

## Verification

- `python3 scripts/dashcam.py status` exits 0 and shows the camera and `relay.installed: true`.
- After a drive, `drives --days 1` lists it with plausible miles and `max_mph`.
- `clips --state pending_upload` shrinks after the phone syncs; `uploaded` grows.
- `test-destination <id>` answers `{"ok": true}` for each destination.
