# Secure Vault — 2026-11-12

Spec: docs/superpowers/specs/2026-11-12-secure-vault-design.md · Mockup: https://claude.ai/artifact/27RvaEWh3W779J5ZDoofXj

- [x] Server: plugins/vault (crypto, store, session, preview, service, tools) + webui/api/vault_routes.py
- [x] iPhone: Settings → Privacy → Secure vault (lock, passcode, folders, viewers, add, select/move, share out)
- [x] iPhone: Face ID approvals for Jarvis's vault tools (vault_show_approvals)
- [x] iPhone: "Jarvis Vault" share extension (write-only inbox)
- [x] Bug sweep (server + iOS) and fixes
- [x] Deployed: server restarted with vault routes + plugin
- [x] Shipped: iPhone build via release.sh (build 263160805)
- [ ] Live check on the phone: set passcode, save a YouTube link (thumbnail + duration), import a photo, play a video

Notes:
- Deployed 2026-11-12 ~08:20 UTC (server 7fd2076ec, webui + gateway restarted).
- Known limit: what vault_read/vault_search return still lands in that chat's transcript (no generic hook yet).
- Protected-path commands (cat/sqlite3 on secrets/ or vault/) need approval, but yolo mode lets them through.
- 6 unrelated iOS test failures (BackgroundLocation x2, InmoOwnerIdentity x4) were already failing in other in-progress work.
- Share extension shares a team Keychain group (VY5CNF8734.com.jarviscopilot.vaultshare), not the App Group: Xcode has no Apple account signed in, so a new App ID with App Groups couldn't be provisioned; the wildcard team profile signs it.
