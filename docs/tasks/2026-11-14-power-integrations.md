# Power Integrations — 2026-11-14

Spec: docs/superpowers/specs/2026-11-14-power-integrations-design.md · Plan: docs/superpowers/plans/2026-11-14-power-integrations.md

Server framework
- [ ] 1. Core types, discovery, validation, `_template`
- [ ] 2. State store: power doc per registry space, seeded once from today
- [ ] 3. Switching, schedule pause/restore, Face ID approvals, per-process manager (webui + gateway)
- [ ] 4. Gates: routes 409, tool calls refused, cache-safe per-chat toolsets, skills, hooks
- [ ] 5. `/api/power` + cards + approvals routes + `power_list` / `power_set` tools
      ✅ 1–5 committed + pushed (4ca03b7a0b); inert until integrations exist; tools add ~84 prompt tokens

The eleven as Power integrations (server)
- [ ] 6. Kanban (off kills running workers), Photon, Security Advisor (protected)
- [ ] 7. Door alarm (off only when disarmed), Car (whole Car page), Vault — all protected
- [ ] 8. iMessage memory, Jarvis Health (uploads keep landing), Dashcam, Widgets, Island designs
      ✅ 6–8 committed + pushed (a879682): all 11 are Power integrations on the server; 80 Power tests green

Devices (after the spinner session commits its shared files)
- [ ] 9. iPhone: PowerState, Power API, Face ID approvals
- [ ] 10. iPhone: Power section, card, page, settings form
- [ ] 11. iPhone: hide/stop every surface (More, Devices, Settings, Health tab, push, CarPlay, Watch, widgets, share)
- [ ] 12. Web: JSON UI renderer (regular integrations get cards on web too)
- [ ] 13. Web: Power section, page, settings, hide off surfaces
- [ ] 14. Mac: native Power section in settings; tray obeys switches
      ✅ 9–14 committed + pushed: iPhone (15 tests), web (9 node tests), Mac pane (dylib rebuilt; also fixed a missing ChatMedia symlink that broke every Mac build)

Finish
- [x] 15. Docs: docs/power-integrations/README.md, AGENTS.md section, template walkthrough (741091e1e4)
- [ ] 16. Bug sweep, deploy server, iPhone release.sh, Mac update, live check of all eleven
      Found: server Tasks 1–7 already live since 19:07 UTC (other session's deploy) — all 6 then-existing integrations on, door alarm answering
      ⏳ code review + security review (2 Opus agents) and full test suite running

Notes:
- Shared checkout with the spinner ("Jarvis loader") session: server first; project.pbxproj, MacSettingsWindow.swift, index.html and iOS Integrations/Settings files wait for its commit.
