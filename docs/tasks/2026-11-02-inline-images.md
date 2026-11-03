# 2026-11-02 — Inline chat images (web, iPhone, Mac)

Spec: docs/superpowers/specs/2026-11-02-inline-chat-images-design.md · Plan: docs/superpowers/plans/2026-11-02-inline-chat-images.md

- [x] 1. Per-chat media store + backstop (agent/chat_media.py) — live 2026-11-03 00:08 UTC
- [x] 2. chat_image tool (save, check, show) — live; real vision check verified (lion matches, "Rokid" lion refused)
- [x] 3. Device images reach the chat (+ jc-client share_image) — live; jc-client updated on the Mac
- [x] 4. Server wiring: backstop on finished replies, job-card thumbnails, media cleanup
- [x] 5. Writing guidance (images beside their text) — first live research reply came back interleaved
- [x] 6. Web: galleries, gallery lightbox, job view + card images — live
- [x] 7. iPhone: galleries, full-screen viewer, job-card thumbnails — build 263062354 published
- [x] 8. Mac: galleries, Preview viewer — build 263062355 published
- [x] 9. Verify + deploy (server suite = same 364 failures as clean base; review fixes in 6c36fd5277)
- [x] 10. Wikimedia 429 → one retry as an identified bot (870015d43)
- [x] 11. Tidy reply footer (his screenshot): web "model · time" + ⓘ details, ↑ icon instead of "to question" pill, quiet "N memories" link, no t/s badge — live
- [x] 12. iPhone tidy footer (model · time, tap for details) — build 263070011 published
- [x] 13. Web chat page unslop: flat near-black + one teal like the phone, sparkle + "Jarvis", quiet sidebar/composer — live 00:19 UTC (f9be85a561)
