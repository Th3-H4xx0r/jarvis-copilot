# GO3 glasses: notification crashes (2026-11-12)

Root cause (proven with PacketLogger + two throwaway test apps): INMO firmware's Bluetooth chip
crashes on any iPhone (ANCS) notification whose app ID is long. Jarvis's ID
`com.jarviscopilot.jarviscopilotMobileAndIOS` is 43 characters; a 20-character test ID is fine,
a 43-character one crashes the same way. Still crashes on firmware 3.0.476 (his test, not captured).
Captures: `inmo-re/captures/gmail-drop-20261112/` (git-ignored).

Decision: wait for INMO to fix the firmware; keep Jarvis alerts off the glasses' ANCS meanwhile.

- [x] Workaround on the phone: Jarvis → Notifications → Lock Screen + Notification Center off (Banners on), old Jarvis notifications cleared. Verified: no drops, native Gmail shows on the lens (with the INMO app connected).
- [x] iMessage cards on the lens: Jarvis had lost its iOS Bluetooth permission at 20:18; turned back on, cards show again. Pushes were waking the app the whole time.
- [x] Firmware 3.0.476 flashed from the Mac (`~/inmo_ota/inmo_ota_full.py`, fixed: directed hotspot join + re-open, since 3.0.x closes an idle hotspot fast).
- [ ] Gmail and other apps don't reach the lens when only Jarvis is connected (INMO app closed). Capture `trialF-jarvis-only.pklg`: no ANCS traffic on the BLE link at all after an iPhone restart. Paused at his request; next step = capture a glasses reconnect with only Jarvis connected.
- [ ] GO3 page warnings: Jarvis Lock Screen / Notification Center alerts back on while iOS shares with the glasses (crash), and Jarvis Bluetooth permission off (no cards), each with a button to the right Settings page.
- [ ] Draft the bug report for INMO (he sends it).
