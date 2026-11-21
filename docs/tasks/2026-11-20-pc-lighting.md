# 2026-11-20 — PC card, 3D model, specs, OpenRGB lighting

Spec: docs/superpowers/specs/2026-11-20-pc-lighting-model-specs-design.md · Plan: docs/superpowers/plans/2026-11-20-pc-lighting-model-specs.md

## PC findings (Task 0, over ssh jc-pc, 2026-11-20)
- Board lighting = **ASRock Polychrome USB** `26CE:01A2` (HID) → OpenRGB drives it over USB, **no PawnIO needed**. PawnIO (msr-driver-rs-pawnio) is installed but Stopped (WattSeal/PC Stats).
- SignalRGB 2.5.86: processes SignalRgb.exe + SignalRgbLauncher.exe (user) + **SignalRgbService** (C:\ProgramData\WhirlwindFX\SignalRgb\service\SignalRgbService.exe). Autostart = HKCU Run value `SignalRgb` → `%LOCALAPPDATA%\VortxEngine\SignalRgbLauncher.exe --silent`.
- SignalRGB drives the Polychrome controller's **3 ARGB channels** (each set up as a generic "Default Strip - 40") + a **12V RGB header** (one colour, not addressable). Real LED counts unknown → calibration finds them.
- winget: `OpenRGB.OpenRGB` 1.1.0 available (also OpenRGB.OpenRGBEffectsPlugin 1.1, not needed — effects are Jarvis's own).
- PC Python 3.12.10 (jc-client) → openrgb-python fine.

## Tasks
- [x] Task 0 — PC verified
- [x] Task 1 — effect engine + golden fixtures
- [x] Task 2 — OpenRGB engine + skills (jc-client)
- [x] Task 3 — specs reader (jc-client)
- [x] Task 4 — setup steps (jc-client)
- [x] Task 5 — server store, routes, Power integration
- [x] Task 6 — Jarvis tools
- [x] Task 7 — iPhone store + effect port
- [x] Task 8 — 3D model
- [x] Task 9 — PC card + page + shared controls
- [x] Task 10 — lighting section, setup, calibration
- [x] Task 11 — specs page + out-of-date
- [x] Task 12 — web
- [x] Task 13a — shipped: server 0cc519ec1 restarted, jc-client updated on the PC (specs arrive live), iPhone release.sh
- [ ] Task 13b — LIVE (needs Pranav): PC page → Set up lighting (Face ID for OpenRGB install), then Show Jarvis each part at the PC; verify each part on the real PC vs the model; check OpenRGB starts headless at login
