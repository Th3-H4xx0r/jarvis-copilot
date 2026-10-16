# 2026-10-14 — Coucou port (agent tracking + Jarvis island)

Spec: `docs/superpowers/specs/2026-10-14-coucou-port-design.md` · Plan: `docs/superpowers/plans/2026-10-14-coucou-port.md`

Pranav: "add FULL functionality of coucou to jarvis" · "Work fully autonomously and parallel bug sweep at the
end and push to all devices after this". A box is ticked only once it is live.

1. [x] Hook pipeline: `jc-hook` relay, shared engine, jc-client hook server, server ingestion, scraper demoted
   - ✅ Built and tested (6 commits, 358 client + 293 root + 263 webui tests green). Goes live with the deploy at the end; the hooks get installed on the Mac after step 2.
2. [x] Approvals + questions v2 (PermissionRequest, AskUserQuestion, Always, auto-dismiss, fingerprints)
   - ✅ Built and tested: the Mac holds the waiting hook; the island or the phone answers the exact request (fingerprint); answered-in-terminal cards disappear; old plugin hooks retired (plugin 0.7.0).
3. [x] iPhone Agents tab, last turn + diffs, notifications, Live Activity, widgets, Control Center, Siri, Focus, Spotlight, history
   - ✅ Agents tab (between Voice and Health), approval/question cards with Face ID, session screen with steps + last turn + diffs + instruction box, notification Always + unlock-to-approve, Live Activity lead session with Allow/Deny on the Lock Screen.
   - ✅ Widgets, Control Center, Siri, Focus filter, Spotlight, History: built and tested.
4. [x] Jarvis.app for Mac: notch island, menu bar, orb, hotkeys, sounds, settings, desktop orb, skins, greeting, demo
   - ✅ Built and tested (Mac 14/14 then): island, menu bar, orb + seasonal skins, desktop orb, shortcuts, sounds, Settings, demo tour; the old tray steps aside.
5. [x] Real plan usage from the Mac's status line + Codex; weekly recap
   - ✅ Codex limits read from `codex app-server` every 5 min, shown next to Claude's on the island and the phone.
   - ✅ Weekly recap (time with overlaps merged, files, lines, approvals, top agent/project, busiest day, longest session) on the phone (Agents → chart button, shareable 1080×1920 image) and the Mac (menu bar → Weekly recap); Monday 8 am notification.
   - ✅ Fixed on the way: approving on the Mac left the phone's copy saying "waiting".
6. [x] Other agents: Codex, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp, Claude Desktop, Cursor, Jarvis itself
   - ✅ `jc-client hooks install --agent codex` (and Mac Settings → Other agents) for each; Jarvis's own runs show via the jarvis-island plugin (cron left out). Codex asks you once to trust new hooks.
7. [x] Services: Stripe, GitHub, Vercel, n8n, Notion, Cal.com, Resend (+ safe actions with Face ID)
   - ✅ Server pollers + iPhone More → Services (detail, Face ID actions, keys) + Mac island Services tab.
8. [x] Crypto watchlist + portfolio (5 exchanges, 16 networks)
   - ✅ Server + iPhone More → Portfolio + Mac island card.
9. [x] Mac chat in the notch, file drop, window context, mail, Apple Music + Spotify
   - ✅ Island tabs: Chat (Jarvis or Ollama/LM Studio, drop files, ⌃⌥W window), Services, Music (Music + Spotify), Mail (Apple Mail inbox, send via Mail or Resend).
10. [ ] "Hey Jarvis" on the Mac, Flow dictation, call note-taker
   - ✅ Built, tested (Mac 98/98) and installed; all three are off until you turn them on in Jarvis.app → Settings → Voice / Flow, or menu bar → Record a call. Not yet tried with a real mic, so not ticked.
11. [x] Parallel bug sweep, deploy server + Mac + iPhone, live end-to-end check
   - ✅ Two sweeps (server/client + Swift): 1 Critical + 20 Important fixed with tests. Live on 2026-10-15: server, jc-client, Jarvis.app, iPhone. Checked live: a real Claude run tracked to the server, an approval from the island path, one from the phone path, Jarvis's own chat on the island.

## Follow-ups (2026-10-15, from Pranav on the phone and Mac)
12. [x] Phone messages reach the live Mac session: handed over when it finishes its current step (any terminal), typed in when it's idle in tmux/iTerm; never a background `claude --resume` copy (one forked this conversation and acted on its own)
   - ✅ Live-tested: queued while working → handed over at Stop → Claude carried on in the same run. Phone wording ships with the next iPhone build.
13. [x] Messages to a Jarvis agent go into that Jarvis chat (not "no terminal or Mac")
   - ✅ Live-tested: reply from Agents → Jarvis answered it as the next turn.
14. [x] Stop the notification spam: the Mac still runs plugin 0.6.5 (old coding_event/pretool hooks on top of the new hooks); "finished" pushes only when worth it
   - ✅ Plugin updated to 0.7.0 in all three projects (takes effect as each Claude session restarts); "Claude finished" now only for turns of a minute or more. Live on the server.
15. [x] The notch island is always there (it vanished when idle), slim, with the orb inside its ear
16. [x] The open island cuts off the session row at the bottom
18. [ ] Agent Live Activities: one per agent type (Claude, Codex, Gemini…) with that agent's logo, started even when the app is closed (push-to-start), and settings in Code Master + Island Designs (on/off, which agents, end after idle, Lock Screen Allow/Deny). Today's single Jarvis activity hides coding whenever voice is up.
17. [x] Instructions-from-phone switch (iPhone + web), Agents tab redesign, real orb, old tray menu items, click-outside folds — shipped 2026-10-15
19. [x] Mac island Music tab: as tall as its content (was a fixed 250 pt with blank space), laid out like Apple's Now Playing
   - ✅ Live on the Mac; checked on the real island with a paused Spotify track.
20. [x] The 5h / wk / Codex pills flicker ~3×/s: every Claude session sends its own stale usage snapshot; keep the highest per window, send only real changes (Mac, server, phone)
   - ✅ Live (jc-client + server): ~80 usage messages/s → only real changes; the Mac app gets usage in its hello.
21. [x] Mac island: opening an agent's details cuts off the bottom — the island grows to fit, and scrolls past the panel with a slim bar on the right
   - ✅ Live on the Mac; an offscreen render of the island with an opened session fits it exactly.
22. [x] iPhone agent chat loads the WHOLE transcript at once (slow): open on the last page, load older pages on scroll up
   - ✅ Live (server + iPhone 18:08+ build): a 1.2 MB chat opens with 331 KB (last 40 messages, tool output/diffs load when opened); polls fetch only new messages.
23. [x] Tray app + notch island together glitch the Mac and burn CPU (idle: tray 8.6%, jc-client 8.2%, Jarvis.app 6.2%; orb draws 30 fps nonstop; two menu-bar items when the app starts after the tray) — brainstorm folding it all into the notch
   - ✅ Live: the Python tray is retired on the Mac (`jc-client start` runs the client + opens Jarvis.app); no menu-bar icon — right-click the notch for the menu; the orb / Hey Jarvis opens Voice in the island; Jarvis.app 19.5 % → ~7 % CPU and 3,041 → 7 idle wakeups with agents working; tray's 14 % gone; opens at login.
24. [ ] iPhone Dynamic Island shows a full-width EMPTY black bar (compact view broken); the Lock Screen Claude activity shows the Jarvis orb instead of the Claude logo (old server → old activity)
   - Installed (static busy ring replaces the compact ProgressView; Claude logo live on the Lock Screen). Waiting on Pranav's phone check before ticking.
25. [x] A "waiting for your OK" alert like coucou's (logo, elapsed timer, Deny / Allow) when an agent asks or needs approval — no Face ID
   - ✅ Live (server + iPhone 19:3x build): one alert per wait, glass Deny/Allow, instant "Allowed ✓" on tap, no Face ID.
26. [ ] Voice: Soniox rejects odd-length audio chunks ("Invalid data length: must be a multiple of 2") — seen 2026-10-15 23:27
27. [ ] Battery: the phone polls /api/island/designs every ~6 s while open
28. [x] Mac: Jarvis lives only in the notch — Python tray retired (`jc-client start` opens Jarvis.app), right-click menu, voice in the island, fluid open/close, mic released on stop, compact coucou-style voice stage, Capture the room fits
29. [x] Mac: each agent's limits in the island (Claude + Codex: session/week bars, reset, deficit/reserved)
30. [ ] Mac: live code view in the island (agent logo + steps + code card, like coucou) — design shown, waiting on Pranav: default when one agent works, or only on click?
31. [ ] Deferred minors from the 2026-10-15 sweep: queued message can be lost at Stop on a very slow link; two voice surfaces share one open flag; right-click roster can be stale; transcript that shrinks >40 msgs can't re-join pages; quick Island-Designs toggles race; failed Lock Screen undo can restore stale state; duplicate "Sent" bubble after paging; after a server restart a still-waiting session alerts once more
32. [x] Mac island Chat tab looks like the phone's chat (orb + "What's on your mind?", soft blue bubbles, model chip, one glass composer with + / send)
   - ✅ Installed on the Mac (dd11d5453e); offscreen renders of a new and a running chat checked.
33. [x] Mac island opens/closes faster (spring 0.55 s → 0.36 s, content fades in sooner)
   - ✅ Installed on the Mac (09a523887d).
34. [x] iPhone "needs you" alert looked off (big ringed logo, cut-off question, heavy grey buttons): who asks beside the camera, amber badge with the timer, the question in full, flat glass buttons
   - ✅ Installed on the iPhone (3a9b80cd5d); renders of the island and Lock Screen checked (approval, Yes/No question, 3 options, Answer in Jarvis).
35. [ ] Answering a Claude question (AskUserQuestion) from the iPhone takes over 15 s to reach the Mac terminal
   - Found (2026-10-15, Pranav testing from the phone): the questions show on the phone, and button answers and typed answers ("Nahhhh") both arrive with the right text. Only the delay is wrong. Next: time each hop from the phone tap to the Mac's waiting hook (phone → server → jc-client → `jc-hook`) to find where the 15 s goes.
36. [x] Mac: the notch's small orb flies into the open island and becomes its big orb (Voice stage, Agents header or tab row), and back into the notch when it folds
   - ✅ Installed on the Mac with jc-client's new voice panel (b965e48fa4); flight path rendered frame by frame, and the real voice panel's orb position checked offscreen. Fixed 45ad3285f4: it flew only the first time and jumped back on fold; now flies both ways every time — checked with a screen recording on the real notch, and Pranav confirmed it works.
37. [ ] Flow dictation really cleaned by Jarvis (code apps were "As said", so VS Code never reached it) + a Clean-up model picker in Settings → Flow
   - Built (b6a05c208c), server deployed, Mac installed; checked through the Mac's proxy on Auto, Haiku 5.5 and Celeris. Waiting on a real dictation.
38. [x] Settings → Shortcuts: record each shortcut from the keys pressed (Esc when done), Press / Hold for Show the island
   - ✅ Installed (1d8b12b455); tab rendered; recording logic tested (digits, arrows, F-keys, moves a taken combo).
39. [x] Flow window → Snippets doesn't work (the trigger field was invisible, so Add stayed greyed out)
   - ✅ Installed (b422c251d7): "When you say" / "Jarvis types" bordered fields, ⌘↩ Add, edit with the pencil; rendered.
40. [x] Flow window → Notes overflows the window: the sidebar is cut off on the left, the note on the right
   - ✅ Installed (b422c251d7): asked 991 pt in a 900 pt window (nested HSplitView); two plain columns now; a test checks every Flow page fits; captured from a real window.
41. [x] Push to talk on one key (hold Right ⌥): listens while held, answers in a small island under the notch that folds after; Talk to Jarvis moved to Settings → Voice
   - Installed (d1765d637a, jc-client dylib updated); small island rendered with the real voice panel; key logic + Flow-key clash tested. Not yet tried with a real hold.
42. [x] Jarvis.app has the Jarvis logo as its icon
   - ✅ Installed; Finder shows it.
43. [x] Push to talk lagged opening and listened late: the echo-cancelling unit took ~1 s to build on the main thread — now a plain mic (~0.1 s), muted after you let go, island opens once audio flows; small island: state under the orb, your words big → grey subtitle when Jarvis answers, "Release to send" while held
   - ✅ Installed (bf12a9d25c, jc-client dylib updated): measured on the real notch, worst frame 14–20 ms (was 1,040 ms), mic up ~0.1 s after the key.
44. [x] Snippets fired inside sentences ("what my email is" → the address): only the whole dictation now
   - ✅ Installed (56212c0165).
45. [ ] Push to talk sends what's on screen (front app, window, a look at it) when you don't give context
   - Built (3d8c1c68e3): a turn from the Mac may read its screen (device_ui_look) unasked and is told to look first; "look at my screen" now counts as an ask (it was refused). Live on the server. Not yet: the front window's name sent with each turn.
46. [x] Siri-style screen-edge glow while holding push to talk (two arcs from the top meet at the bottom; back to the top when it ends), toggle in Settings
47. [x] Mac island Chat: match the phone's chat exactly, harness / single model choice in Settings, the + file picker opens behind the island, full tools like the regular chat agent
   - ✅ Installed (a2a03214aa): phone layout (Jarvis label, grouped tool rows, markdown), approval + question cards (it hung on approvals before — that was the "cancelled"), Stop shows "Stopped", MEDIA:/markdown images inline, no endless "Thinking…", Settings → General → Island chat (default / harness / single model). Not yet tried with a live turn.
48. [x] Picking a file from the island chat's + folded the island (the picker's clicks look like clicks elsewhere)
   - ✅ Installed (dbf1b542a1).
49. [x] "Look at my screen" → "I can't access your Mac screen from this request" (the Mac gate only knew "on my screen")
   - ✅ Live on the server (restarted 07:14 UTC, 3d8c1c68e3).
50. [x] Every turn names the device it came from, exactly as registered ("Pranavs-MacBook-Pro.local", "JarvisCopilot (iPhone)", "Jarvis Pod"); jc-client counts as the Mac for reading its screen
   - ✅ Live on the server (0b10876a3d, restarted 07:29 UTC).
51. [x] When a voice turn hands off to a harness agent ("I'll have a larger model compare…"), speak its answer when it's back, and show that agent's job (task, steps, result) in the island's Agents tab
   - ✅ Deployed (server 4e9352ac84 restarted 07:52 UTC, Mac app + dylib 87071ec981): hand-offs listed in the Agents tab (model, state, clock, steps, answer, Read aloud/Copy); a voice hand-off's answer is spoken on the Mac in the small island when it's back. Not yet tried live. To check: possible double speech when a voice connection is still open (app speaks + server audio); a speak-back is lost if Jarvis.app isn't running.
52. [ ] With several monitors, holding push to talk brings the notch island to the screen the pointer is on, lights that screen, and Jarvis's look reads that screen
   - Built: the island comes to the pointer's display for the talk (and a hand-off's answer), home after the fold; the glow follows it; jc-client hears the display (`talk_screen`) and for 3 min `ui_look` with no app reads the app on top of that screen (its window there), or the bare screen with its text read when nothing's open. Live test on his 4 displays passed (island + glow on each, home after each fold; looks read Brave on the right monitor, the desktop on empty ones).
53. [x] Remove Services, the portfolio and Mail everywhere — the island keeps Agents, Chat, Music (Spotify/Apple Music) and Voice
   - Built: Mac island Services + Mail tabs, their panes, MailController, the services/portfolio topics and the demo's services step gone; jc-client's jarvis_island skill no longer offers services/mail; server `jarvis_services` package, `/api/services` routes and the polling thread deleted; iPhone More → Services / Portfolio screens deleted. Live: server restarted 16:37 UTC (`/api/services` 404), Mac app + jc-client installed. iPhone: installed 12:32 CDT (Release build with the battery round's changes).
54. [ ] Code Master → glasses: nothing reached the lens with the Glasses channel on; the phone should pop the Dynamic Island too
   - Causes: with phone approvals on, questions/approvals skipped every Code Master channel (only the Allow/Deny banner went out); a glasses card was an alert-only push, which runs no app code on a locked phone (lens only via the ESP32 relay); a wake-only card was deferred by iOS.
   - Built (c615a2f4ee, 7973a2cb3c): the glasses card rides on the banner the phone shows (Allow/Deny, Finished/Failed) and that push wakes the app; the agent Live Activity pops the island once for a finished (≥60 s) or failed turn, as Mobile/Focus allow. Server restarted 20:19 UTC; iPhone installed. Waiting on a check on the lens.

## Shipped
- 2026-10-15: the whole port is live (server f062666ae+, Jarvis.app, iPhone build af06c84f09).

## For you
- Codex: the next time you start it, it asks once to trust Jarvis's new hooks — say yes.
- Jarvis.app: macOS will ask for Accessibility (Flow paste, ⌃⌥W window title), Automation (Music, Spotify, Mail, Terminal), Microphone and Speech Recognition the first time each feature runs.
- Turn on Hey Jarvis / Flow in Jarvis.app → Settings if you want them, and try Record a call once.
- Apple Watch was unreachable: its app installs itself when the watch reconnects to the phone.
