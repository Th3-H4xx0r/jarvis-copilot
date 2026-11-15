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
- [ ] Island redesign to match the Mac (orb shader on GPU, spring motion, theme, every pane): built + installed on the PC, side-by-side shots match; tick once he's happy with it live
- [x] Core: link client, models/state, gaming guard, theme/loader/prefs, voice logic, Holo logic, screen-share protocol + cc_state, OTA flow + updater (420 tests, Mac)
- [ ] WPF/Win32 halves built and compile-checked on the Mac (616 Core tests): island + Agents tab, tray/hotkeys/sounds/recap, Settings, Power + admin UI, voice engine + wake word + push-to-talk, Live, Flow, notes, chat/music, Holo card/BLE/chirp, capture/WebRTC/Command Center, update card. Tick once each runs on the PC.
- [x] Push-to-talk restored in voice Core
- [ ] PC screen share sharp + smooth (own VP8 encoder: native 1440p, ~6.6 Mbps CBR, 8 threads, keyframe on PLI); 1440p scroll bench 7.4 ms/frame, 34 dB. Tick once he's watched it on the phone.
- [ ] Wake PC over Wi-Fi: Mac jc-client updated (wol_send), packets also unicast + subnet broadcast. Not yet proven from real sleep (his own wakes came first). Tick after a real Wake PC from the phone.
- [ ] Unlock PC: he must Trust my iPhone, save the password/PIN and Install the helper in Settings → PC power (build 263192207), then Unlock on the phone (build 263192209). Helper verified to refuse while unlocked; real lock-screen typing untested.
- [ ] Holo Drop round 3: stays open on outside clicks (drag in), clipboard by default, Clipboard/File…/Screenshot; real app icon; chat attachment thumbnails. Tick once checked live.
- [ ] Round 2 fixes (build 263192121, installed): tray menu is a native Win32 menu (closes on Quit/any click); capsules no longer drawn as ovals (WPF radius clamp, app-wide); Holo Drop Orbit redrawn as the Mac's panel with close/Esc/click-outside; click outside the island folds it; Settings redrawn as the Mac's (sidebar tiles, grouped cards, switches, pop-ups). Tick once he's checked them live.

## Known gaps / follow-ups
- Island: Segoe UI not SF Pro; no compact push-to-talk island; chat replies plain text (no markdown); model menu has no harnesses; Voice chip opens settings, not a session picker.
- PC screen share (phone -> PC) not yet tried live after the os fix.
- Windows app: island chat model/harness picker in General not built yet.
- Windows app screen share sends no brightness or Wi-Fi name, so those Command Center tiles hide on the phone.
- Windows app task shares don't record a replay.
- Holo grab on Windows has no "front document"; it goes straight to selected text.
- Computer control on the PC has no OCR fallback yet (UIA only).
- Uninstalling the Windows app leaves the JarvisUnlock service (needs admin: `"C:\Program Files\Jarvis\JarvisUnlock.exe" --uninstall`).
- iPhone Agents shows PC admin requests on the Face ID card, not yet as a row under Needs you.
