# Game Streaming — 2026-11-21 (overnight, autonomous)

His report: setup said "Host unreachable" vs "Sunshine is running", pairing "didn't go through", spinner never ends after saving the real password.

- [x] REAL root cause: jc-client's dispatcher calls skills as fn(**args); the game_stream handlers took one dict, so {"sunshine":…} was unwrapped into a BLANK login (Sunshine 401 on every call) and multi-key payloads (pair/detect/connect) raised TypeError. His password was right all along. Fixed 36c9ec77fb (+ tests through skills.invoke). Live: status reachable, Mac + Desktop/Steam Big Picture, detect username root.
- [x] Pairing uses Sunshine's real API — GET /api/pin pending {pairings:[{id,name,address}]} → POST {pairing_id,pin,name}; csrf key csrf_token (a6f2bbac48, e62f16f49a, c1b4cecac0). Live: /pair with nobody waiting → "No device is waiting… open Moonlight and tap your PC".
- [x] Status refresh + no endless spinner, needs_login vs offline copy, username autofill, iOS pair sheet (8bb0e2132a), web parity (57261ce982). iPhone OTA published (release.sh exit 0).
- [x] Watcher restarts after reconnect (re-push on subscribe; fresh webui follows the Power switch) + seeds known clients from localhost (3252a57bcf). Live: "(1 known clients)".
- [x] Watcher reads Sunshine's REAL log lines (CLIENT CONNECTED/DISCONNECTED, Executing/Spawning [..]) + apps.json names; "unknown device" alert is now "X wants to pair" from polling pending pairs (18f41c8f00).
- [x] PC asleep 04:19: SYSTEM task JarvisSleepTonight (04:45 backstop) + disabled Wi-Fi WAKE (RZ616 woke it ~10 s after every sleep, source "Unknown").
- [ ] Wi-Fi wake is OFF on the PC — check-ins (15-min RTC) + keyboard still wake it; Pod Wake-on-LAN only lands at a check-in. Revert if he wants: `powercfg /deviceenablewake "RZ616 Wi-Fi 6E 160MHz"`.
- [ ] Delete leftovers on the PC: task JarvisSleepTonight, %LOCALAPPDATA%\JarvisSleepTonight.{py,cmd}, jarvis_sleep_last.txt, jarvis_sleep_err.txt, jarvis_suspend_diag.*, jarvis_probe.txt.
- [ ] Not yet seen live: pairing a real device (needs him + a PIN), the live "streaming now" flag and start/stop/pair alerts on a real stream, streaming to the Mac/TV.
- [ ] POST /api/agents/mac/let-sleep answered "not found" for device c8c9cd5c… — check the Agents "Sleep PC" button works.
- [ ] Test-infra flake: webui tests share ~/.jarviscopilot/webui-test-* across parallel files (FileExistsError / sqlite) — pass alone or -j 1.
