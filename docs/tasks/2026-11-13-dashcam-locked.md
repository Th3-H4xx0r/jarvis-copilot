# Dashcam: tagged clips locked, never deleted (2026-11-13)

His Oct 21 accident clip (tagged Accident) wouldn't play and he feared it was deleted. It wasn't:
the server was down, then Google Drive's sign-in had expired (consent screen still in Testing).
Both lenses are in Drive, plus a second copy in `Dashcam Camry SE 2026/Locked/`.

- [x] Server: any tag locks a clip (no cloud delete / forget / card delete; tagging cancels a queued card delete), Locked-folder copy in Drive, locked clips upload first. Live (2fa342b65, 96aec7244); accident clips verified locked + copied.
- [ ] iPhone (shipped as build 263171821, commit 47ca3b40b5; not yet checked on his phone): DashcamLock guards on every delete path (phone, SD card, Jarvis tools, CarPlay), locked clips kept on phone + restored from Drive, upload right away, "Google Drive is signed out → Sign in" popup. Reviewed by an independent Opus pass; all 9 findings fixed; 280 Dashcam tests pass. Check on the phone: update, open the Oct 21 clip (lock line, plays after Drive sign-in), try deleting it (refused).
- [ ] HIS: publish the Google consent screen (Google Auth Platform → Audience → Publish app) so Drive stops signing out every 7 days.
