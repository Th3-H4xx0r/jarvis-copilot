# 2026-11-05 — CarPlay + dashcam bug fixes

His report: the server keeps connecting/disconnecting; on plugging into CarPlay the dash shows a mic
symbol and Spotify sounds wrong until he starts and stops Jarvis listening; opening Jarvis pauses the
car's music; after that workaround the app loses the server and dashcam clips stop syncing; clips
often only back up once he opens the app's Dashcam page.

Tick only when he confirms it live.

- [ ] Server connection stops flapping. Cause: the Agents list push was 1.23 MB (1,575 iMessage-memory
      runs), past the iPhone socket's 1 MiB limit → "Message too long" (bridge.drop.NSPOSIX.40) and
      reconnect, over and over while the Agents tab was open. Server lists an integration's newest 50
      runs + `total`; phone allows 16 MiB messages; the server logs any frame over 1 MiB.
- [ ] No mic symbol on the dash / Spotify normal when CarPlay connects. Cause: since "Talk to JARVIS
      here" was first used (Oct 27) the background keepalive held a recordable (play-and-record)
      session, which opens the car's voice channel. With CarPlay as the route it now holds plain playback.
- [ ] Opening Jarvis in the car doesn't pause the music (same cause: the keepalive re-activating its
      recordable session on open).
- [ ] After a CarPlay voice turn the app stays connected and the dashcam keeps syncing. Cause: iOS
      wouldn't restart the recordable keepalive from the background after the turn
      (keepalive.restart_failed 5–18 an hour), so the app was suspended.
- [ ] Dashcam clips sync on a drive without opening the app. Causes: (a) asleep on cellular, Jarvis
      never noticed CarPlay — location wakes (every ~5 min on a drive) now re-check the car and the
      camera's Wi‑Fi; (b) the camera's Wi‑Fi was only re-checked with the app open — now also in the
      background while in the car or for 2 min after a Wi‑Fi change.
