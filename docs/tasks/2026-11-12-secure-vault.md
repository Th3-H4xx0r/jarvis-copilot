# Secure Vault — 2026-11-12

Spec: docs/superpowers/specs/2026-11-12-secure-vault-design.md · Mockup: https://claude.ai/artifact/27RvaEWh3W779J5ZDoofXj

- [x] Server: plugins/vault (crypto, store, session, preview, service, tools) + webui/api/vault_routes.py
- [x] iPhone: Settings → Privacy → Secure vault (lock, passcode, folders, viewers, add, select/move, share out)
- [x] iPhone: Face ID approvals for Jarvis's vault tools (vault_show_approvals)
- [x] iPhone: "Jarvis Vault" share extension (write-only inbox)
- [x] Bug sweep (server + iOS) and fixes
- [x] Deployed: server restarted with vault routes + plugin
- [x] Shipped: iPhone build via release.sh (build 263160805)
- [x] Round 2 (his 08:24 feedback): cleaner vault home (folder rows, Search/Add/⋯ pill, empty states)
- [x] Round 2: share sheet shows no folders; server inbox forces the top folder; app deletes the old Keychain folder list
- [x] Round 2: smarter link previews (crawler → Safari → Twitterbot, wall titles dropped, more image sources,
      oEmbed discovery, title from the link) + "Refresh preview"; old thumbnail-less links refetched once
- [x] Round 2 deployed (server 491deae6a, webui restarted 14:40 UTC)
- [x] Round 2 shipped: iPhone build 263161440 via release.sh
- [x] Round 3: previews fall back to a headless Chromium on the server (plugins/vault/render.py, guard proxy) — deployed 15:02 UTC (6dea44836)
- [x] Round 3: private in-app browser (VaultBrowser.swift): Open page asks Private / Default; EasyList+EasyPrivacy blocking, pop-up blocker, nothing kept
- [x] Round 3 shipped: iPhone build 263161502 via release.sh
- [ ] Live check: the private browser on the phone (blocker compile time on device, pop-up bar, lock closes it)
- [ ] Live check: his xhamster1.desi link gets a real title/thumbnail (couldn't test that site from here: it serves bots no listings)
- [ ] Live check on the phone: set passcode, save a YouTube link (thumbnail + duration), import a photo, play a video

Notes:
- Deployed 2026-11-12 ~08:20 UTC (server 7fd2076ec, webui + gateway restarted).
- Known limit: what vault_read/vault_search return still lands in that chat's transcript (no generic hook yet).
- Protected-path commands (cat/sqlite3 on secrets/ or vault/) need approval, but yolo mode lets them through.
- 6 unrelated iOS test failures (BackgroundLocation x2, InmoOwnerIdentity x4) were already failing in other in-progress work.
- Share extension shares a team Keychain group (VY5CNF8734.com.jarviscopilot.vaultshare), not the App Group: Xcode has no Apple account signed in, so a new App ID with App Groups couldn't be provisioned; the wildcard team profile signs it.
