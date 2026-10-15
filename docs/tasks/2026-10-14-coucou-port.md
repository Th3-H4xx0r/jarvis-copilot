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
12. [ ] Phone messages reach the live Mac session: handed over when it finishes its current step (any terminal), typed in when it's idle in tmux/iTerm; never a background `claude --resume` copy (one forked this conversation and acted on its own)
13. [ ] Messages to a Jarvis agent go into that Jarvis chat (not "no terminal or Mac")
14. [x] Stop the notification spam: the Mac still runs plugin 0.6.5 (old coding_event/pretool hooks on top of the new hooks); "finished" pushes only when worth it
   - ✅ Plugin updated to 0.7.0 in all three projects (takes effect as each Claude session restarts); "Claude finished" now only for turns of a minute or more. Live on the server.
15. [ ] The notch island is always there (it vanished when idle), slim, with the orb inside its ear
16. [ ] The open island cuts off the session row at the bottom
18. [ ] Agent Live Activities: one per agent type (Claude, Codex, Gemini…) with that agent's logo, started even when the app is closed (push-to-start), and settings in Code Master + Island Designs (on/off, which agents, end after idle, Lock Screen Allow/Deny). Today's single Jarvis activity hides coding whenever voice is up.
17. [x] Instructions-from-phone switch (iPhone + web), Agents tab redesign, real orb, old tray menu items, click-outside folds — shipped 2026-10-15

## Shipped
- 2026-10-15: the whole port is live (server f062666ae+, Jarvis.app, iPhone build af06c84f09).

## For you
- Codex: the next time you start it, it asks once to trust Jarvis's new hooks — say yes.
- Jarvis.app: macOS will ask for Accessibility (Flow paste, ⌃⌥W window title), Automation (Music, Spotify, Mail, Terminal), Microphone and Speech Recognition the first time each feature runs.
- Turn on Hey Jarvis / Flow in Jarvis.app → Settings if you want them, and try Record a call once.
- Apple Watch was unreachable: its app installs itself when the watch reconnects to the phone.
