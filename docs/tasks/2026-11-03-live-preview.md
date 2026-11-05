# 2026-11-03 — live browser + Mac screen: live test

- [x] Steel cloud move fell back to Lightpanda: Steel's websocketUrl has no "/" path, agent-browser 400s. Fixed dad9c968f, deployed, live-tested (move, live view, replay).
- [x] Phone spun "Open Jarvis on your Mac": the Mac ran the old app (263070639). Installed 263071708.
- [ ] Mac share ends at once: Jarvis.app has no Screen Recording grant ("Jarvis can't see your screen…"). Needs Pranav at the Mac: Screen & System Audio Recording + Accessibility → Jarvis, then Quit & Reopen.
- [ ] (shipped 7e8067dd51, tick when seen) iPhone shows "The share has ended." instead of the share's `error` (MacScreenViewer.swift `ended()` ignores `share["error"]`). Show the reason.
- [ ] (fixed 6d94d9dd03: reply id clobbered by JcLink + typing during loginwindow rebuild; Mac 263072246 + jc-client updated — tick after a real unlock) Unlock Mac from the phone fails: jc-client logs "The Jarvis Mac app didn't answer" for every unlock since 00:41, yet dots land in the lock-screen field and it stays locked (dot count differed between tries: 11 vs 13 → typed password is wrong/garbled). Attempts 12:46 and 12:47.
- [ ] Notch orb slid under the notch when the right ear was empty (Group dropped its frame). Fixed, Mac 263072234 published — tick when he confirms.
- [ ] (shipped Mac cfd496a28b / iOS 7e8067dd51) Mac live view Command Center (iPhone): Control Center tiles (Wi-Fi, Bluetooth, AirDrop, Focus, Dark Mode, Stage Manager, Mirroring, Now Playing, brightness, volume), Unlock/Lock/Sleep/Keep awake, Mac shortcuts, open-apps strip; over the share's data channel (Unlock via Face ID flow).
- [ ] (shipped 7e8067dd51) Mac live view landscape: screen left, slim button column right.
- [ ] (shipped cfd496a28b) Multi-display share: pick the display in Command Center, switches live.
- [ ] (fixed cd55f37dc2, webui restarted 22:47 UTC) Web job view: working dots in a grey track + running-tool dot off the row.

## Computer-use skills (evening)

- [ ] (shipped 86f3a61f21, synced on hermes) 8 computer-use skills: web-task-router, flight-travel-search, web-forms-logins, web-watch-jobs, mac-control, mac-app-recipes, mac-screen-look, mac-dev-setup. Tick after a real browser task and a real Mac task go right in one try.
- [ ] (shipped 4fc70b995d, jc-client updated) `device_vscode_run`: VS Code folder + command in VS Code's own terminal. Not triggered live yet.
- [ ] (shipped 5c0e890a37 / 59a361b42b / 9b92b83364, deployed) Mac OK lasts the chat; device tools never silently pick a device + `ran_on`; no clipboard reads unless he asks.
- [x] Leaked Anthropic key (Oct 9 chat fa76e0e2f8bd) + 2 old OAuth tokens redacted from state.db and coding_sessions.db (secure_delete on). The leaked key is still LIVE in auth.json/.env → Pranav must rotate it. Old copy of one dead token remains in coding_sessions.db.bak-retag (Oct 21 backup).
- [x] Server disk hit 100% (44 GB) → now 83% (7.4 GB free): npm cache + journal trimmed; bloat-backup-20261011 and May/Sep state-snapshots deleted (his OK); cron outputs capped at newest 200 per job (1229f518bf, gateway restarted 00:49 UTC) — the every-minute email Reminder job had 231k files; 295k old outputs pruned, verified capped at 200 after a live run.

## Live Activity redesign (night)

- [ ] (shipped 9c467a0baf + 38a4280f50, iPhone builds 263080440 + fix build (1f9e47ef07) published; layouts verified as real activities in the simulator) Workout Live Activity for every sport, black and white (white disc, white timer, red heart only); buttons: lifting weight −/+, reps −/+, ✓ log set; resting −15s / +15s / Skip; other sports Pause / Resume. Tick after a real gym session logs a set from the Lock Screen.
- [x] (shipped 9c467a0baf + 1f9e47ef07, confirmed on his phone: question card fits with margins) Claude / agent Live Activity + in-app request card black and white: no state rings, pills, fleet bar or amber; "Allow Bash?" over the command; white Allow with black text. Tick when he sees one on the phone.
- [x] (fixed 6d6a5e8895, webui restarted 05:30 UTC; confirmed: test 3 question came up in the new island, build 263080538) Agent Live Activity stopped starting: swiping the broken cards away (or the app update ending them) suppressed Claude for the whole episode, which never ends while he's working. Now hidden only until the agent's next turn or wait on you. Tick when he sees it come back on its own.
- [ ] (shipped af00ab171f, iPhone 263080632) Whole app black and white: JcAccent.hex white + role tokens (JcButton, JcMetric, onFill/control); Agents-style grey buttons with one radius system; white fill only for a screen's one main action; Voice buttons grey; Health colours kept. Mac app not rebuilt yet (shares JcAccent). Tick when he's looked through the app on the phone.

## Small UI fixes (Nov 4 morning)

- [ ] (shipped 965eea0e52) Settings: switch rows no longer squeeze their text (the B&W switch stretched under labelsHidden); header redone as one left-aligned This device card (name edited in place + "● Connected · host"). Tick when he's seen it.
- [ ] (shipped 965eea0e52) Icon colours back on Devices / Smart Band / Health: status, battery, heart, steps pills, measure list, band readings. Tick when he's seen it.
- [ ] (shipped 965eea0e52) Chat + Voice harness chip shows only the harness symbol. Tick when he's seen it.
- [ ] Integration setup runs the picked model alone, never the default harness (the harness turned setup into a background job he couldn't answer; the top model picker was ignored). Server-side, 9ec4fc8239, webui restarted 20:46 UTC; no app update needed. Tick when a real setup chat answers on the picked model.
- [ ] Dashcam sync Live Activity redone black and white like the workout/Claude ones (his pick from mockups): compact = arrow + percentage in a box wide enough for 100% (it clipped "1%"), expanded = car disc + camera name, big "clips left", a row + white bar per transfer, clip names as "Rear · 7:19 PM". Checked as real activities in the sim (16e Lock Screen, 17 Pro island expanded + compact). Tick when he sees it during a real sync.
