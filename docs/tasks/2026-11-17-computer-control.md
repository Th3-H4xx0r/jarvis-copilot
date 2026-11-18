# Computer control + agent-desktop — 2026-11-17

Evaluating vercel-labs/agent-desktop (v1.3.1) for Jarvis computer control.

His asks
- [ ] 2. The PC is called "Mac" (offline PC card title, status lines, popups, pushes): server names it from its paired record / "PC" (`device_name`, `mac_power`, `agents_core` + `owner_os` on session rows), iPhone (card, password/unlock sheets, Screen viewer, command center, session rows/screen), web (helper sweep). Tick once live on his phone.

Found while mapping the current system
- [ ] 1. PC busy refusal never counts: `ui_win.py:175` says "You're using the PC…" but `agent/computer/loop.py:27` `_REFUSED` only matches "isn't in front" / "using the Mac", so the loop keeps going on the PC until another guard stops it.
- [x] 3. PC game mode false positive: an idle PC reported "in a game (fullscreen textinputhost.exe)" (Windows' touch-keyboard/IME host) and refused every look — system hosts excluded in game_mode.py (2026-11-17).
- [ ] 4. PC on/off status on the iPhone Agents card is unreliable (doesn't flip Awake/Asleep/Offline/Waking, goes stale) — investigate + safeguards for every edge case (his ask 2026-11-17).
- [ ] 5. PC Remote Desktop / Screen sometimes fail — investigate + safeguards.
- [ ] 6. Unlock PC: Windows shows "please enter PIN" + OK on the lock screen but Jarvis reports success — detect it and report the real outcome.
- [ ] 7. Live: the planner plans Mac apps for the PC ("System Settings", "Finder") — tell it which computer it drives.
- [ ] 8. Live: PC open_app fails even for "Calculator" (Start-Process: file not found) — resolve Windows app names.
- [ ] 9. Live: the fallback model clicked window controls (close / zoom / full screen) nobody asked for — guard them like Allow/Accept.
- [ ] 10. Live: "Visual Studio Code" isn't found on the Mac (its process is "Code").
- [ ] 11. Live: Anthropic API credit balance is empty — every @anthropic-api call (his Computer fallback/planner, Haiku) fails. HIS ACTION: top up, or switch the Computer node fallback.
Live series (Terra fallback, Anthropic credits empty): Finder Downloads 4.6 s (Oct 5.6), Settings Wi-Fi 3.5 s (Oct 6.1, no surface misfire), Calendar 8.9 s (Oct 7.1), Calculator 18.9 s (planner wrote one '23*4' step: no batch), Notes false done (clicked Close), File › New Folder via agent-desktop menu path ✓, Wi-Fi name read ✓, VS Code not found, notifications wandered; PC: all three failed at open_app.

Deployed 2026-11-17 (not yet confirmed by him): server + Mac/PC jc-client with every fix above; iPhone builds 263212314 (PC naming) and 263220033 (PC waking/Screen retry); Windows app 263220046 (unlock checks Windows unlocked, Screen says why after RDP, game grace, lock state) + unlock helper refreshed.
Still to try live: a real locked-screen unlock (normal lock and after Remote Desktop); Screen after Remote Desktop; the ≥30% speed target once his Anthropic API credits are topped up.
