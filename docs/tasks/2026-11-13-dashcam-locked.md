# Dashcam: tagged clips locked, never deleted (2026-11-13)

His Oct 21 accident clip (tagged Accident) wouldn't play and he feared it was deleted. It wasn't:
the server was down, then Google Drive's sign-in had expired (consent screen still in Testing).
Both lenses are in Drive, plus a second copy in `Dashcam Camry SE 2026/Locked/`.

- [x] Server: any tag locks a clip (no cloud delete / forget / card delete; tagging cancels a queued card delete), Locked-folder copy in Drive, locked clips upload first. Live (2fa342b65, 96aec7244); accident clips verified locked + copied.
- [ ] iPhone: DashcamLock guards on every delete path (phone, SD card, Jarvis tools, CarPlay), locked clips kept on phone + restored from Drive, upload right away, "Google Drive is signed out → Sign in" popup. Built + reviewed; fixing review findings, then ship with release.sh.
- [ ] HIS: publish the Google consent screen (Google Auth Platform → Audience → Publish app) so Drive stops signing out every 7 days.
