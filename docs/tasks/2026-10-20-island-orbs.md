# 2026-10-20 — Mac island orbs

- [x] The orb beside "Agents" in the island opens Voice (it did nothing).
- [x] A click on the notch's orb opens Voice and starts listening once the
      stage is open (after the spring and the orb's flight). Needs the new
      dylib (`startListening`) and Jarvis.app.
- [x] The tab row's orb (beside the fold arrow) sometimes opened push to
      talk's small voice island: `voiceMini` outlived the push-to-talk turn.
      Leaving Voice now forgets it.

Live on the Mac 2026-10-20 18:18 (Jarvis.app rebuilt, jc-client on 90eb6223d3).
