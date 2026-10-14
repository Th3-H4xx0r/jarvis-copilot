# 2026-10-14 — Coucou port (agent tracking + Jarvis island)

Spec: `docs/superpowers/specs/2026-10-14-coucou-port-design.md` · Plan: `docs/superpowers/plans/2026-10-14-coucou-port.md`

Pranav: "add FULL functionality of coucou to jarvis" · "Work fully autonomously and parallel bug sweep at the
end and push to all devices after this". A box is ticked only once it is live.

1. [ ] Hook pipeline: `jc-hook` relay, shared engine, jc-client hook server, server ingestion, scraper demoted
   - ✅ Built and tested (6 commits, 358 client + 293 root + 263 webui tests green). Goes live with the deploy at the end; the hooks get installed on the Mac after step 2.
2. [ ] Approvals + questions v2 (PermissionRequest, AskUserQuestion, Always, auto-dismiss, fingerprints)
   - ✅ Built and tested: the Mac holds the waiting hook; the island or the phone answers the exact request (fingerprint); answered-in-terminal cards disappear; old plugin hooks retired (plugin 0.7.0).
3. [ ] iPhone Agents tab, last turn + diffs, notifications, Live Activity, widgets, Control Center, Siri, Focus, Spotlight, history
   - ✅ Agents tab (between Voice and Health), approval/question cards with Face ID, session screen with steps + last turn + diffs + instruction box, notification Always + unlock-to-approve, Live Activity lead session with Allow/Deny on the Lock Screen.
   - 🔨 Widgets, Control Center, Siri, Focus filter, Spotlight, History: built, testing now.
4. [ ] Jarvis.app for Mac: notch island, menu bar, orb, hotkeys, sounds, settings, desktop orb, skins, greeting, demo
5. [ ] Real plan usage from the Mac's status line + Codex; weekly recap
6. [ ] Other agents: Codex, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp, Claude Desktop, Cursor, Jarvis itself
7. [ ] Services: Stripe, GitHub, Vercel, n8n, Notion, Cal.com, Resend (+ safe actions with Face ID)
8. [ ] Crypto watchlist + portfolio (5 exchanges, 16 networks)
9. [ ] Mac chat in the notch, file drop, window context, mail, Apple Music + Spotify
10. [ ] "Hey Jarvis" on the Mac, Flow dictation, call note-taker
11. [ ] Parallel bug sweep, deploy server + Mac + iPhone, live end-to-end check

## Shipped

## For you
