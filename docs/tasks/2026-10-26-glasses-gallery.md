# 2026-10-26 — Glasses gallery (previews + Save & download all)

Spec: docs/superpowers/specs/2026-10-26-glasses-gallery-design.md (local) · Plan: docs/superpowers/plans/2026-10-26-glasses-gallery.md (local)

- [x] 1. Library model: photo / video items from the inventory, dates from names, saved record that lasts
- [x] 2. Video sound merge (glasses .opus → AAC into the .mp4) + thumbnails
- [x] 3. Save & download all: one Wi‑Fi session, photos first, Photos add-only, Jarvis copy removed after save
- [x] 4. Gallery grid on the glasses page + full gallery + `glasses_media_save_all` tool
- [ ] 5. Bug sweep, push, install on the phone
- [ ] 6. Live check with the glasses: photos + videos (with sound) land in the camera roll, phone back on normal Wi‑Fi

Bug sweep (2 Opus reviewers) fixed: a failed .opus fetch saved the video silent for good (now retryable);
packets ending in 0x0a were split a byte early (real files: 2 dropouts → 0); glasses_media_cancel didn't stop
a batch; a dropped glasses Wi-Fi hung each item 180 s (15 s connect timeout + batch stops, screen kept awake);
Photos-saved-but-record-write-failed could save twice; Cancel before the batch owned the session could kill
another download; saved tiles opened Photos mid-batch; killed-app leftovers swept at launch (>1 h old).
Unrelated: InmoOwnerIdentityTests fail in the unsigned simulator run (keychain unavailable) — untouched code.
