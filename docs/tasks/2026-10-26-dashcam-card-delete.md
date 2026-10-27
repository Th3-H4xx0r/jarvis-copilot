# 2026-10-26 — Dashcam: delete off the card after download + a pending-deletion backlog

He said: "it doesn't automatically delete clips as soon as it downloads to my phone. It should be doing this one
clip at a time; as soon as it downloads, it should send the command to delete that clip on the dash cam right
away" and "the dash cam keeps running out of space". Plus: deletes made away from the car (dashcam only, or
everywhere) go wherever they can right away, the dashcam part waits in a backlog **stored on the server
permanently**, shows as pending deletion, and is flushed the moment the phone is on the camera's Wi‑Fi.

His picks: **keep the download rules** (unpulled clips stay for the camera's loop); **"it should just keep
showing all the clips like it does in the same order, but those need deletion, it just marks it in the UI"**.

Design: docs/superpowers/specs/2026-10-26-dashcam-card-delete-design.md

- [x] 1. Design — he said to work autonomously from here; my calls are in the spec ("Calls made after the builder check")
- [x] 2. Server: backlog on the clip record (`card_delete`) + `/card_deletes` routes (140ea83b81, bb1956950d) — live on
  jc-hermes 2026-10-27 01:57 UTC. Bug sweep: a listing never closes an entry (short listings); only the phone's `done`.
- [x] 3. Phone: delete each clip off the card right after its download (once its size held), plus a sweep each pass of
  clips already on the phone or in the cloud (370a3aae4f, 55d94d45d8) — installed 2026-10-27
- [x] 4. Phone: backlog flush at pass start + push at launch (60be9dff98). The 7 old clips: the server had already
  forgotten them (the old 'everywhere' bug), so they stay on the phone's list and go on the next connection
- [x] 5. Phone: "Delete everywhere" keeps the clip until the card delete happens — seen live: his 2 clips (00:12)
  marked on the server 02:15 UTC, still in the library
- [x] 6. Phone UI: "Pending deletion" mark in place (library row + player); "only copy" warning
- [x] 7. Agent: `dashcam_delete_file` queues when away
- [ ] 8. Live: clips leave the A4 one by one; note whether plain deletes work while recording

Bug sweep (2 Opus reviewers): short listings closing entries (server + phone), size-held check before any card
delete, parked re-check per file in the playback batch, server told what left the card in the same pass.
Unrelated, pre-existing: tests/skills/test_jarvis_ring_skill.py::test_sdk_covers_every_ring_skill_the_phone_advertises (21 vs 13).
