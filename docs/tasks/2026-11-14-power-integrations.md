# Power Integrations — 2026-11-14

Spec: docs/superpowers/specs/2026-11-14-power-integrations-design.md · Plan: docs/superpowers/plans/2026-11-14-power-integrations.md · Guide: docs/power-integrations/README.md

Server framework
- [x] 1. Core types, discovery, validation, `_template`
- [x] 2. State store: power doc per registry space, seeded once from today
- [x] 3. Switching, schedule pause/restore, Face ID approvals, per-process manager (webui + gateway)
- [x] 4. Gates: routes 409, tool calls refused, cache-safe per-chat toolsets, skills, hooks
- [x] 5. `/api/power` + cards + approvals routes + `power_list` / `power_set` tools (~84 prompt tokens)

The eleven as Power integrations (server)
- [x] 6. Kanban (off kills running workers), Photon, Security Advisor (protected)
- [x] 7. Door alarm (off only when disarmed), Car (whole Car page), Vault — all protected
- [x] 8. iMessage memory, Jarvis Health (uploads keep landing), Dashcam, Widgets, Island designs

Devices
- [ ] 9. iPhone: PowerState, Power API, Face ID approvals — published build 263181958 (tick once installed)
- [ ] 10. iPhone: Power section, card, page, settings form — same build
- [ ] 11. iPhone: hide/stop every surface (More, Devices, Settings, Health tab, push, CarPlay, widgets, dashcam) — same build
- [x] 12. Web: JSON UI renderer (regular integrations get their page UI on web too)
- [x] 13. Web: Power section, page, settings, hide off surfaces
- [x] 14. Mac: native Power section in settings (jc-client updated on the Mac, dylib 2d09919b)

Finish
- [x] 15. Docs: docs/power-integrations/README.md, AGENTS.md section, template walkthrough
- [x] 16. Review (2 Opus reviewers) + one fix pass, full suite (no new failures), deploy, live check
      ✅ Server deployed 0cbb33c85 (webui + gateway restarted 20:06 UTC): all 11 on as before; door alarm answering; old state docs migrated
      ✅ Live round trip: Widgets off → 409 → on; Jarvis switching the Car off → Face ID approval; Jarvis changing HASS_URL → refused
      ⚠️ That test left an "off:car" Face ID request on the phone for 2 minutes — ignore it if you saw it

Shipped
- Server 0cbb33c85 · iPhone build 263181958 (in-app update) · Mac client synced to 0cbb33c85

For you
- Install the iPhone update, open Integrations → Power: switch something harmless (Widgets, Island designs) off and on and watch it hide/return.
- Try switching the Door alarm off while armed (refused) and Vault off (Face ID card).
- Deferred follow-ups are listed in the session's final message.
