# Secure Vault — 2026-11-12

Spec: docs/superpowers/specs/2026-11-12-secure-vault-design.md · Mockup: https://claude.ai/artifact/27RvaEWh3W779J5ZDoofXj

- [ ] Server: plugins/vault (crypto, store, session, preview, service, tools) + webui/api/vault_routes.py
- [ ] iPhone: Settings → Privacy → Secure vault (lock, passcode, folders, viewers, add, select/move, share out)
- [ ] iPhone: Face ID approvals for Jarvis's vault tools (vault_show_approvals)
- [ ] iPhone: "Jarvis Vault" share extension (write-only inbox)
- [ ] Bug sweep (server + iOS) and fixes
- [ ] Deployed: server restarted with vault routes + plugin
- [ ] Shipped: iPhone build via release.sh
- [ ] Live check on the phone: set passcode, save a YouTube link (thumbnail + duration), import a photo, play a video
