# Remote Desktop (RDP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-tap Remote Desktop into his Windows PC (real Microsoft RDP) from the Jarvis iPhone app, the Jarvis web app and his Mac, with Face ID sign-in, clipboard, files and sound, reachable only over Tailscale.

**Architecture:** The PC (Windows 11 Pro after his upgrade) runs Windows' RDP server, firewalled to Tailscale. A new Power integration `remote-desktop` on the server owns `/api/rdp`: sessions (with game/local-use warnings), the Face ID approval (the Unlock chain with `kind: "rdp"`), a WebSocket→TCP relay for the iPhone (embedded FreeRDP), and a Guacamole tunnel to a local `guacd` for the web. The PC app releases the saved Microsoft-account password per approved session — encrypted to the iPhone's Secure-Enclave key for the iPhone, in memory to the server for the web. The Mac opens Microsoft Windows App with an `.rdp` file.

**Tech Stack:** Python webui (wsproto WebSockets, `api/tcp_relay.relay_pump`), Debian `guacd`, guacamole-common-js (vendored, exact version), FreeRDP 3.x xcframework (iOS), SwiftUI/CryptoKit, C#/.NET 8 WPF (Windows app), jc-client (Python), Docker xrdp test target.

**Spec:** `docs/superpowers/specs/2026-11-15-remote-desktop-design.md`

## Global Constraints
- RDP reachable only from `100.64.0.0/10` (Tailscale); NLA required.
- His Windows password is never written on the server, never logged; on the PC only DPAPI (`%LOCALAPPDATA%\Jarvis\rdp.secret`, separate from the Unlock secret).
- A session needs his Face ID on the iPhone every time; Jarvis never starts one by itself.
- Game in front, or PC keyboard/mouse input in the last 120 s while unlocked → `{"warn": ...}`; proceed only with `confirm: true`.
- Integration off = relay + tunnel closed, guacd connections dropped, Windows RDP switched off and the firewall rule removed (via the LocalSystem helper, no UAC).
- After a session the PC stays on the lock screen (no `tscon`).
- Idle disconnect: 30 min (setting `idle_minutes`, default 30). Web file transfers ≤ 2 GB each, per-session drive folder deleted when the session ends.
- Gaming rules on the PC: no surface over a fullscreen game, no focus theft, no FPS cost.
- Pins: guacamole-common-js `1.5.5` vendored at `webui/static/vendor/guacamole-common-1.5.5.min.js`; FreeRDP 3.x pinned by tag + commit SHA in `ios_app/vendor/freerdp/VERSION`; xrdp test image pinned by digest.
- iPhone ships only via `ios_app/scripts/release.sh`. Tests via `scripts/run_tests.sh` (webui files also pass under `cd webui && pytest`).
- Jarvis look on every new screen (app tokens, JcUnified on iPhone, `--jc-*` on web).

## Review Focus
1. PC asleep or offline when Remote Desktop is tapped → "pranav-computer is asleep" with Wake, never a hanging spinner (Task 1 `test_session_refused_when_asleep_or_offline`).
2. Face ID denied or not answered in 60 s → session `cancelled`, relay/tunnel refuse to open, no credential released (Task 2 `test_denied_or_expired_approval_releases_nothing`).
3. Saved password wrong/changed → NLA failure shows "Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)" on iPhone and web (Task 4 `test_guac_auth_error_maps_to_password_message`; Task 8 `testNlaFailureMessage`).
4. Phone drops the connection briefly (lock/network switch) → reconnect within 60 s without a new Face ID, using only the in-memory credential; after 60 s a new Face ID (Task 8 `testReconnectWindow`).
5. Integration switched off mid-session → live relay and tunnel close within 2 s (Task 3 `test_off_closes_live_relays`, Task 4 `test_off_closes_tunnels`).

---

### Task 1: Server — integration, PC status, sessions

**Files:**
- Create: `jarvis_power/integrations/remote_desktop/__init__.py`, `jarvis_power/integrations/remote_desktop/ui.json`
- Create: `webui/api/rdp_sessions.py`, `webui/api/rdp_routes.py`
- Modify: `webui/api/mounts.py` (add `("/api/rdp", "api.rdp_routes")`), `jarvis_power/surfaces.py` (`ios.remote_desktop`, `web.remote_desktop`, `windows.remote_desktop`, `mac.remote_desktop`)
- Test: `webui/tests/test_rdp_sessions.py`, `tests/jarvis_power/integrations/test_remote_desktop.py`

**Interfaces:**
- Produces: `RdpStatus` dict posted by the PC: `{"device_id", "edition", "rdp_enabled": bool, "firewall_scoped": bool, "username", "tailscale_ip", "idle_s": float, "locked": bool, "game": str|None, "remote_session": bool, "has_password": bool}`.
- Produces: `rdp_sessions.create(device_id: str, client: Literal["ios","web"], confirm: bool, enc_pub: str|None) -> dict` returning either `{"warn": "game"|"in_use", "game_name"?: str}`, `{"error": str, "code": "asleep"|"offline"|"not_ready"|"no_password"|"edition"}`, or `{"session": {"id", "state": "approving", "expires_at"}}`; `get(sid) -> Session|None`; `Session` fields `id, device_id, client, state ("approving"|"approved"|"connected"|"cancelled"|"ended"), host, port=3389, username, enc_pub, credential (in memory only: web plaintext or iOS ciphertext dict), created, last_activity`; `end(sid, reason: str)`; `on_off()` cancels everything.
- Routes: `POST /api/rdp/status` (PC), `POST /api/rdp/sessions`, `GET /api/rdp/sessions/<id>` (state; for iOS includes the ciphertext `credential` once approved, never plaintext), `DELETE /api/rdp/sessions/<id>`, `GET /api/rdp/audit`.

- [ ] **Step 1: Failing tests** — `test_session_refused_when_asleep_or_offline` (mac_power state asleep → code `asleep`; no status for 90 s → `offline`), `test_warn_game_then_confirm` (status game `cod.exe` → `{"warn":"game","game_name":"Call of Duty"}` via `pc_stats_games.name_of`; with `confirm=True` → `approving`), `test_warn_in_use` (`idle_s=30, locked=False` → `in_use`; `idle_s=30, locked=True` → no warning), `test_not_ready_codes` (Home → `edition`; `rdp_enabled=False` → `not_ready`; `has_password=False` → `no_password`), `test_get_never_returns_plaintext`; integration test: manifest valid, `route_prefixes == ("/api/rdp",)`, settings keys `idle_minutes`, `warn_game`, `allow_web`, `transfer_folder`.
- [ ] **Step 2: Run** `scripts/run_tests.sh webui/tests/test_rdp_sessions.py tests/jarvis_power/integrations/test_remote_desktop.py` → FAIL (module missing).
- [ ] **Step 3: Implement** the integration (copy `_template`; `processes=("webui",)`, `toolsets=("remote_desktop",)`, `stop()` calls `rdp_sessions.on_off()`), the lock-guarded in-memory session table (approval TTL 60 s, idle end after `idle_minutes`), the latest-status store and routes. Asleep comes from `api.mac_power` (`sleeping_at`).
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(rdp): remote-desktop integration, PC status and sessions`.

### Task 2: Approval and credential release chain (server + jc-client)

**Files:**
- Modify: `desktop_client/jc_client/password_broker.py`, `desktop_client/jc_client/pc_power.py`, `webui/api/mac_power.py`, `webui/api/rdp_sessions.py`
- Test: `desktop_client/tests/test_password_broker_rdp.py`, `webui/tests/test_rdp_sessions.py`

**Interfaces:**
- Consumes: Task 1 `Session`.
- Produces: server → PC frame `{"type": "rdp_credential_request", "session_id", "client", "context"}`, where `context` = canonical JSON `{"session": id, "client": "ios"|"web", "enc_pub": base64|null, "device": name}` (≤ 2400 chars; his signature covers it). jc-client runs `PasswordBroker.request("rdp", context)` → Face ID on the iPhone ("Connect to pranav-computer from your iPhone" / "…from the web") → broadcasts to the app `{"type": "password_release", "id", "kind": "rdp", "context", "nonce", "proof": {"ts", "signature"}}`.
- Produces: app → jc-client → server `{"type": "rdp_credential", "session_id", "ok": bool, "error"?: str, "credential": {"ciphertext","ephemeral_pub","nonce"} (ios) | {"password": str} (web)}`; the server stores it on the session (`state: "approved"`); web plaintext only in memory.

- [ ] **Step 1: Failing tests** — broker: `test_rdp_request_context_is_signed_verbatim`, `test_rdp_one_release_per_request`; server: `test_denied_or_expired_approval_releases_nothing` (deny → `cancelled`; no answer in 60 s → `cancelled`; a late `rdp_credential` for a cancelled session is dropped), `test_credential_only_for_matching_session`, `test_web_password_never_logged` (caplog has no password).
- [ ] **Step 2: Run** `scripts/run_tests.sh desktop_client/tests/test_password_broker_rdp.py webui/tests/test_rdp_sessions.py` → FAIL.
- [ ] **Step 3: Implement** — the broker accepts `kind="rdp"` alongside `unlock`/`sudo` (same Face ID path, title "Connect to <device>"); `pc_power` forwards `rdp_credential_request` and relays `rdp_credential` up; the server sends the request on session create and fills the session on reply.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(rdp): Face ID approval and per-session credential release`.

### Task 3: iPhone relay (WebSocket → PC:3389)

**Files:**
- Create: `webui/api/rdp_relay.py`
- Modify: `webui/server.py` (WebSocket dispatch: try `api.rdp_relay.handle_websocket` before `api.voice`)
- Test: `webui/tests/test_rdp_relay.py`

**Interfaces:**
- Consumes: Task 1 `get(sid)`, `end`, `on_off`; `api.tcp_relay.relay_pump(a: Channel, b: Channel)` and its `Channel`.
- Produces: `wss://<host>/api/rdp/relay/<session_id>` — binary frames both ways; accepted only for a session with `client=="ios"` in state `approved` (→ `connected`); one connection per session; closes after `idle_minutes` without bytes or on `end`/off. Target = the session's `host` (the PC's Tailscale IP) and port 3389 only.

- [ ] **Step 1: Failing tests** (loopback TCP echo as the "PC", in-memory WS channel as in the tcp_relay tests): `test_relay_requires_approved_ios_session` (approving/web/unknown → refused), `test_relay_single_use`, `test_relay_pumps_bytes_both_ways`, `test_off_closes_live_relays` (≤ 2 s), `test_relay_target_is_fixed`.
- [ ] **Step 2: Run** `scripts/run_tests.sh webui/tests/test_rdp_relay.py` → FAIL.
- [ ] **Step 3: Implement** with `ws_upgrade` + `relay_pump`; register live relays in `rdp_sessions` so `on_off`/`end` close them.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(rdp): WebSocket relay for the iPhone client`.

### Task 4: Web gateway (guacd + Guacamole tunnel)

**Files:**
- Create: `webui/api/rdp_guac.py`, `deploy/guacd/README.md`, `scripts/dev/xrdp-test.sh` (starts the pinned xrdp container on :3390, and guacd on :4822, for tests/dev)
- Modify: `webui/server.py` (WS dispatch `/api/rdp/guac/<session_id>`)
- Test: `webui/tests/test_rdp_guac.py`

**Interfaces:**
- Consumes: Task 1/2 session with a web credential.
- Produces: `wss://<host>/api/rdp/guac/<session_id>?w=&h=&dpi=` speaking the Guacamole protocol to the browser. Server-side handshake to `127.0.0.1:4822`: `select rdp`, then `size`, `audio` (`audio/L16`), `video`, `image` (`image/png`, `image/jpeg`, `image/webp`), `connect` with `hostname`=session host, `port`=3389, `username`, `password` (from memory), `security`=`nla`, `ignore-cert`=`true`, `resize-method`=`display-update`, `enable-drive`=`true`, `drive-name`=`Jarvis`, `drive-path`=`<HERMES_HOME>/rdp/drive/<session_id>`, `create-drive-path`=`true`, `enable-audio-input`=`false`, `color-depth`=`24`; then a byte proxy. Helpers `guac_encode(opcode: str, *args: str) -> str` (length-prefixed elements, `;`-terminated) and `guac_parse(buf: str) -> list[list[str]]`.
- Error map: guacd `error` for auth failure (statuses `0x0301`, `0x0207`, or the RDP "logon failure" message) → an instruction the client shows as "Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)".

- [ ] **Step 1: Failing tests** with a fake guacd socket: `test_guac_encode_parse_roundtrip` (lengths count code points), `test_handshake_args_exact`, `test_tunnel_requires_approved_web_session`, `test_guac_auth_error_maps_to_password_message`, `test_drive_folder_removed_on_end`, `test_off_closes_tunnels`, `test_upload_limit_2gb` (the drive folder watcher deletes and reports any file over 2 GB).
- [ ] **Step 2: Run** `scripts/run_tests.sh webui/tests/test_rdp_guac.py` → FAIL.
- [ ] **Step 3: Implement** the tunnel. `deploy/guacd/README.md`: `apt install guacd libguac-client-rdp0` (Debian 13), bind 127.0.0.1 in `/etc/guacamole/guacd.conf`, `systemctl enable --now guacd`.
- [ ] **Step 4: Run** → PASS. Manual: `scripts/dev/xrdp-test.sh`, then connect through the tunnel from a scratch page; the xrdp desktop renders and typing works.
- [ ] **Step 5: Commit** `feat(rdp): Guacamole gateway for the web client`.

### Task 5: Windows app — setup, saved password, status

**Files:**
- Create: `windows_app/Jarvis.Core/Remote/RdpSetup.cs` (pure: builds the PowerShell for setup/repair/off), `windows_app/Jarvis/Remote/RemoteDesktop.cs` (status poster every 60 s and on change, password save/clear, setup via `AdminRunner`)
- Modify: `windows_app/Jarvis/AppHost.cs` (create it; add its section to `PcPowerPane.Extras`)
- Test: `windows_app/Jarvis.Tests/Remote/RdpSetupTests.cs`

**Interfaces:**
- Produces: `RdpSetup.SetupScript(string tailscaleCidr = "100.64.0.0/10", int idleMinutes = 30) -> string`, `RdpSetup.OffScript() -> string`, `RdpSetup.Username(string? upn, string user) -> string` (`MicrosoftAccount\<upn>` when a UPN exists, else `.\<user>`). The setup script sets `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections=0`; `...\WinStations\RDP-Tcp\UserAuthentication=1`; disables the built-in Remote Desktop firewall group (`@FirewallAPI.dll,-28752`); creates rule `Jarvis Remote Desktop (Tailscale)` TCP+UDP 3389 `-RemoteAddress 100.64.0.0/10`; sets `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` `AVC444ModePreferred=1`, `bEnumerateHWBeforeSW=1`, `MaxIdleTime=<minutes × 60000>`; sets `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device\DevicePasswordLessBuildVersion=0`.
- Produces: `RemoteDesktop.Status() -> JsonObject` (Task 1 `RdpStatus`): edition from `Win32_OperatingSystem.Caption`, `idle_s` from `GetLastInputInfo`, `locked` from the session-lock events, `game` from `AppState.GameMode`, `remote_session` from `SystemParameters.IsRemoteSession`, `username` via `RdpSetup.Username(whoami /upn)`, `tailscale_ip` from `tailscale ip -4`.
- Settings UI (PC power → Remote Desktop): Home → "Needs Windows 11 Pro" + Upgrade (`ms-settings:activation`); Pro → status rows (RDP on, Tailscale-only firewall, Hello-only off), **Set up** / **Repair** (Face ID + UAC), "Microsoft account password for Remote Desktop" Save/Change/Remove (PasswordBox; `Dpapi.Protect` → `rdp.secret`).

- [ ] **Step 1: Failing tests** — `SetupScript_contains_every_setting` (each key/value above appears exactly once), `Setup_firewall_scoped_to_tailscale_only`, `OffScript_reverses_rdp_and_rule`, `Username_for_microsoft_account` (`krish@x.com` → `MicrosoftAccount\krish@x.com`; none → `.\krish`).
- [ ] **Step 2: Run** `windows_app/scripts/pc-test.sh` → FAIL.
- [ ] **Step 3: Implement**; post to `/api/rdp/status` (409 = integration off → pause until settings say on).
- [ ] **Step 4: Run** → PASS; build; on the PC (still Home) the section shows "Needs Windows 11 Pro".
- [ ] **Step 5: Commit** `feat(rdp): Windows setup, saved password and status`.

### Task 6: Windows app — credential release, helper on/off, pausing PC surfaces

**Files:**
- Create: `windows_app/Jarvis.Core/Remote/RdpRelease.cs`, `windows_app/Jarvis.Core/Crypto/Ecies.cs`
- Modify: `windows_app/Jarvis/Remote/RemoteDesktop.cs`, `windows_app/JarvisUnlock/Program.cs` (pipe command `{"rdp": "on"|"off"}` runs `RdpSetup.SetupScript()`/`OffScript()` as LocalSystem — only these two), `windows_app/Jarvis/Island/IslandWindow.cs`, `windows_app/Jarvis/Stats/DashboardWindow.cs`, `windows_app/Jarvis/Screen/ScreenShareSession.cs`
- Test: `windows_app/Jarvis.Tests/Remote/RdpReleaseTests.cs`, `windows_app/Jarvis.Tests/Crypto/EciesTests.cs`, vector `windows_app/Jarvis.Tests/Crypto/ecies_vector.json`

**Interfaces:**
- Consumes: Task 2 `password_release`; `UnlockApproval.Verify(context, kind, nonce, ts, signature, key, now)` with kind `"rdp"`.
- Produces: `Ecies.Encrypt(byte[] plaintext, byte[] recipientP256X963) -> (byte[] Ciphertext, byte[] EphemeralPubX963, byte[] Nonce)` — ECDH P-256 → HKDF-SHA256 (salt empty, info `"jarvis-rdp-v1"`, 32 bytes) → AES-256-GCM (12-byte nonce, 16-byte tag appended). Must open on iOS with `SecureEnclave.P256.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement` → `hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("jarvis-rdp-v1".utf8), outputByteCount: 32)` → `AES.GCM.open`.
- Produces: `RdpRelease.Handle(JsonObject release, byte[] pinnedKey, Func<string?> readPassword, DateTimeOffset now) -> JsonObject` → the Task 2 `rdp_credential` frame (ios: ECIES to the `enc_pub` inside the signed context; web: `{"password"}`), or `{ok:false,error}` on bad signature/kind/context or no saved password.
- Integration on/off: the app follows PowerState `remote-desktop` and sends the helper `rdp on|off`.
- While `SystemParameters.IsRemoteSession` is true: the island stays hidden, the PC Stats window hides, a running screen share ends; all return when the session is local again.

- [ ] **Step 1: Failing tests** — `Ecies_roundtrip_with_test_vector` (the vector's fixed private key decrypts `Encrypt` output; Task 8 reuses the vector), `Release_refuses_wrong_kind_or_bad_signature`, `Release_web_returns_password_only_for_web_context`, `Release_ios_encrypts_to_signed_enc_pub` (an `enc_pub` outside the signed context is ignored).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**; release off the UI thread; never log secrets.
- [ ] **Step 4: Run** → PASS; deploy to the PC (helper reinstall: Face ID + UAC once).
- [ ] **Step 5: Commit** `feat(rdp): PC releases the password per approved session; helper switches RDP on/off`.

### Task 7: Web client

**Files:**
- Create: `webui/static/vendor/guacamole-common-1.5.5.min.js`, `webui/static/rdp.js`, `webui/static/rdp_core.js`, `webui/static/rdp.css`, `webui/static/rdp.test.js`
- Modify: the web Agents PC card (Remote Desktop button next to Screen), `webui/static/index.html` (includes, gated by `data-power="remote-desktop"`)
- Test: `webui/static/rdp.test.js`, `webui/tests/test_rdp_js.py`

**Interfaces:**
- Consumes: Task 1 routes, Task 4 tunnel.
- Produces: `RdpCore.flow(state, event) -> state` — `idle → checking → warn (game|in_use) → approving ("Approve on your iPhone") → connecting → connected → ended|error`; error copy per code (`asleep` → "pranav-computer is asleep" + Wake through the existing mac-power wake call; `no_password`; `edition`; password refused).
- Session page: full window, top bar (device, quality, Ctrl+Alt+Del, Win, clipboard, Upload, Files, fullscreen, Disconnect), drag-and-drop upload to the `Jarvis` drive, file list/download via Guacamole filesystem objects, clipboard both ways, audio, `display-update` resize on window resize.

- [ ] **Step 1: Failing node tests** — `flow: asleep shows Wake`, `flow: warn then confirm goes approving`, `flow: approval timeout ends with message`, `flow: password refused message`, `upload refuses files over 2 GB before sending`.
- [ ] **Step 2: Run** `cd webui/static && node --test rdp.test.js` → FAIL.
- [ ] **Step 3: Implement**; Jarvis look; vendored 1.5.5 with its licence header.
- [ ] **Step 4: Run** → PASS; check in Chrome against the xrdp target through local guacd (screenshots 1600 and 393 wide).
- [ ] **Step 5: Commit** `feat(rdp): web Remote Desktop client`.

### Task 8: iPhone client

**Files:**
- Create: `ios_app/vendor/freerdp/build-xcframework.sh`, `ios_app/vendor/freerdp/VERSION`; under `ios_app/JarvisCopilot/Copilot/Agents/RemoteDesktop/`: `RdpClient.swift` (FreeRDP wrapper), `RdpLoopbackBridge.swift` (127.0.0.1 listener ↔ `wss …/api/rdp/relay/<id>`), `RdpSessionModel.swift`, `RdpSessionView.swift`, `RdpKeyboardBar.swift`, `RdpCredentials.swift`, `RdpTransfers.swift`
- Modify: `AgentsMacPowerCard.swift` (Remote Desktop for Windows PCs), the PC Tools list and action picker (a "Remote Desktop" action), project wiring as the repo does for frameworks
- Test: `ios_app/JarvisCopilotTests/Agents/RemoteDesktopTests.swift`

**Interfaces:**
- Consumes: Task 1 routes (`client: "ios"`, `enc_pub` = the Secure-Enclave key's X9.63 public key, base64), Task 3 relay, Task 6 ECIES format + `ecies_vector.json`.
- Produces: `RdpSessionModel` with the same states as `RdpCore.flow`; `RdpCredentials.open(ciphertext: Data, ephemeralPub: Data, nonce: Data) throws -> String` (memory only, zeroed on end); reconnect within 60 s reuses it, later → a new session + Face ID.
- Session view: full screen, session size = view size × scale (rotation resizes via the display-control channel), pinch zoom/pan, trackpad gestures (tap click, two-finger tap right click, two-finger drag scroll, long-press drag), keyboard bar (Esc, Tab, Ctrl, Alt, Win, arrows, Ctrl+Alt+Del, Ctrl+C/V/Z), system keyboard, clipboard (cliprdr), sound (rdpsnd), files: drive redirection of `Documents/Jarvis Transfer` + "Send to PC" (picker → Holo Drop), quality indicator, Disconnect.

- [ ] **Step 1: Failing tests** — `testEciesOpensVector` (software key from the vector), `testReconnectWindow`, `testNlaFailureMessage`, `testStatesMatchWebFlow`, `testRemoteDesktopActionInPicker` (Windows PC card lists it; Mac card doesn't).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**; build FreeRDP 3.x for iOS arm64 + simulator into an xcframework (script pins tag + SHA; artefact cached outside git if > 50 MB).
- [ ] **Step 4: Run** → PASS; simulator → xrdp target through a local relay (dev flag): desktop renders, typing and clipboard work; render card, warning, approving and session screens at 393 wide.
- [ ] **Step 5: Commit** `feat(rdp): iPhone Remote Desktop with FreeRDP`.

### Task 9: Mac launch, Jarvis tool, audit, docs

**Files:**
- Modify: the Mac app's PC actions under `mac_app/Sources/` ("Remote Desktop" writes `~/Library/Caches/Jarvis/<device>.rdp` and opens it with Windows App, bundle id `com.microsoft.rdc.macos`; missing → its App Store page); web on a Mac offers "Open in Windows App" (downloads the same `.rdp`).
- Create: `tools/remote_desktop_tool.py` (toolset `remote_desktop`: `remote_desktop_status` → ready/edition/live sessions; no connect tool); add to `toolsets.py`
- Modify: the Security page (iPhone + web) to list RDP sessions from `GET /api/rdp/audit`
- Test: `tests/tools/test_remote_desktop_tool.py`, a Mac unit test for the `.rdp` lines
- `.rdp` lines: `full address:s:<tailscale_ip>`, `username:s:<username>`, `prompt for credentials:i:0`, `redirectclipboard:i:1`, `audiomode:i:0`, `drivestoredirect:s:*`, `dynamic resolution:i:1`, `screen mode id:i:2`, `authentication level:i:2`.

- [ ] **Step 1: Failing tests** — the tool returns `{"ready": bool, "edition", "sessions": [...]}` with no secrets; the `.rdp` has every line above.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(rdp): Mac Windows App launch, Jarvis status tool, audit`; update `docs/tasks/2026-11-15-windows-client.md` and memory.

### Task 10: Deploy and verify on the real PC (after his Pro upgrade)

- [ ] Deploy the server (ff-merge on jc-hermes, restart webui + gateway), install guacd per `deploy/guacd/README.md`, release the iPhone via `release.sh`, package + install the Windows app.
- [ ] PC (Pro): Settings → PC power → Remote Desktop → Set up (Face ID + UAC); save the Microsoft password; all status rows green; from the server `nc -z 100.119.223.124 3389` succeeds; from a non-Tailscale address it fails.
- [ ] iPhone: connect while idle → desktop, clipboard both ways, send a photo, hear a sound; connect while CoD runs → game warning; deny Face ID → nothing connects.
- [ ] Web: same checks in Chrome; download a file from the `Jarvis` drive.
- [ ] Mac: Remote Desktop opens Windows App with address + username.
- [ ] Integration off → sessions drop within 2 s, `fDenyTSConnections=1`, firewall rule gone; on again → restored.
- [ ] After disconnecting, the PC's monitors show the lock screen; the island and dashboard return after he signs in at the desk.
