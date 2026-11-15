# Windows client — task list (2026-11-15)

Design: `docs/superpowers/specs/2026-11-15-windows-client-design.md` · plans: `docs/superpowers/plans/2026-11-15-windows-client-0{0,1,2,3}-*.md` (local, gitignored).
Tick only when it works live on the PC / phone.

## Needs Pranav
- [x] The gaming PC is "pranav-computer" (100.119.223.124)
- [x] Run the one-time setup on the PC (normal PowerShell, click Yes once):
  `irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/windows/setup-pc.ps1 | iex`
- [ ] Install the iPhone update (build 263191127).

## Then (me, over SSH)
- [x] Read `~\jarvis-setup\summary.txt`; set `User` in the Mac's `Host jc-pc` (krish); fix any FAIL lines
- [x] Pair jc-client headlessly (`jc-client pair --server … --code …` with a code minted on the server), then `jc-client start`
- [ ] PC inventory (Python/winget/agents on PATH/anti-cheat games/Wi-Fi wake capability) → `docs/windows/pc-inventory.md`
- [ ] PC dev checkout + venv; run the jc-client suite on Windows; fix what only Windows shows (plan 01 Task 12)
- [ ] Install jc-client on the PC (installer), pair it; confirm the PC card appears in Agents (iPhone + web)
- [ ] `jc-client update` on the Mac (so the Mac offers `wol_send` to wake the PC) — held back overnight to not risk the Mac's notch
- [ ] Build + package the Windows app on the PC (`windows_app/scripts/pc-package.sh`), install, first run; publish via `scripts/publish-app-update.sh --platform windows`
- [ ] Computer control live check: "on my PC, open Notepad and type hello"
- [ ] Wake PC: check the Wi-Fi adapter's wake-on-magic-packet; real wake test from the phone
- [ ] Screen share + Command Center from the iPhone against the PC
- [ ] Gaming check with a real fullscreen game: no island, no focus change, FPS unchanged, ui_do refuses
- [ ] Parity walkthrough of spec §6 → `docs/windows/parity-2026-11.md`

## Windows app (plan 03)
- [x] App installed on the PC: Start Menu (search), Settings > Apps + uninstall, app owns jc-client (hidden task via conhost --headless; tray Restart/Stop), tray icon fixed
- [ ] Island redesign to match the Mac pixel for pixel (orb, motion, theme, every screen) — helper running, verified with side-by-side shots
- [x] Core: link client, models/state, gaming guard, theme/loader/prefs, voice logic, Holo logic, screen-share protocol + cc_state, OTA flow + updater (420 tests, Mac)
- [ ] WPF/Win32 halves built and compile-checked on the Mac (616 Core tests): island + Agents tab, tray/hotkeys/sounds/recap, Settings, Power + admin UI, voice engine + wake word + push-to-talk, Live, Flow, notes, chat/music, Holo card/BLE/chirp, capture/WebRTC/Command Center, update card. Tick once each runs on the PC.
- [x] Push-to-talk restored in voice Core

## Known gaps / follow-ups
- Windows app: island chat model/harness picker in General not built yet.
- Windows app screen share sends no brightness or Wi-Fi name, so those Command Center tiles hide on the phone.
- Windows app task shares don't record a replay.
- Holo grab on Windows has no "front document"; it goes straight to selected text.
- Computer control on the PC has no OCR fallback yet (UIA only).
- iPhone Agents shows PC admin requests on the Face ID card, not yet as a row under Needs you.
