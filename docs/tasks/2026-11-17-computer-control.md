# Computer control + agent-desktop — 2026-11-17

Evaluating vercel-labs/agent-desktop (v1.3.1) for Jarvis computer control.

His asks
- [ ] 2. The PC is called "Mac" (offline PC card title, status lines, popups, pushes): server names it from its paired record / "PC" (`device_name`, `mac_power`, `agents_core` + `owner_os` on session rows), iPhone (card, password/unlock sheets, Screen viewer, command center, session rows/screen), web (helper sweep). Tick once live on his phone.

Found while mapping the current system
- [ ] 1. PC busy refusal never counts: `ui_win.py:175` says "You're using the PC…" but `agent/computer/loop.py:27` `_REFUSED` only matches "isn't in front" / "using the Mac", so the loop keeps going on the PC until another guard stops it.
- [ ] 3. PC game mode false positive: an idle PC reported "in a game (fullscreen textinputhost.exe)" (Windows' touch-keyboard/IME host) and refused every look — system hosts excluded in game_mode.py (2026-11-17).
