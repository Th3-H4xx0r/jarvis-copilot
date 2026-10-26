# 2026-10-26 — Dashcam: delete off the card after download + a pending-deletion backlog

He said: "it doesn't automatically delete clips as soon as it downloads to my phone. It should be doing this one
clip at a time; as soon as it downloads, it should send the command to delete that clip on the dash cam right
away" and "the dash cam keeps running out of space". Plus: deletes made away from the car (dashcam only, or
everywhere) go wherever they can right away, the dashcam part waits in a backlog **stored on the server
permanently**, shows as pending deletion, and is flushed the moment the phone is on the camera's Wi‑Fi.

His picks: **keep the download rules** (unpulled clips stay for the camera's loop); **"it should just keep
showing all the clips like it does in the same order, but those need deletion, it just marks it in the UI"**.

Design: docs/superpowers/specs/2026-10-26-dashcam-card-delete-design.md

- [ ] 1. Design approved
- [ ] 2. Server: `card_deletes.json` backlog + routes + inventory auto-close + `delete_pending` on clips
- [ ] 3. Phone: delete each clip off the card right after its download checks out (refusal → backlog)
- [ ] 4. Phone: backlog flush at pass start (server + local mirror), migrate the 7 queued clips
- [ ] 5. Phone: "Delete everywhere" keeps the clip until the card delete happens; batched multi-select
- [ ] 6. Phone UI: "Pending deletion" mark in place (library row + player)
- [ ] 7. Agent: `dashcam_delete_file` queues when away
- [ ] 8. Live: clips leave the A4 one by one; note whether plain deletes work while recording
