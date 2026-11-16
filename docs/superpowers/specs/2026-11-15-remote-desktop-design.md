# Remote Desktop (RDP) for the Windows PC — design (2026-11-15)

## Intent
He asked for "a proper RDP protocol for the windows one … it would be nice to have those features".
Today Jarvis has a watch-and-steer live screen share (WebRTC VP8, `windows_app/Jarvis/Screen/`). He wants a
real remote desktop to **work on the PC remotely, do quick checks and fixes, and move files and clipboard**,
opened **inside the Jarvis iPhone app, the Jarvis web app, and from his Mac**.

## His decisions (from the questions)
1. **Route: upgrade the PC to Windows 11 Pro** (it runs 11 Home, which cannot host RDP) → the real Microsoft
   RDP server. He buys/does the upgrade (Settings → System → Activation → Upgrade your edition; no reinstall).
2. **Uses:** remote work, quick checks/fixes, files and clipboard (not game streaming).
3. **Clients:** inside the Jarvis iPhone app; Jarvis web app; Mac = **Microsoft's Windows App** opened from
   Jarvis with everything filled in (not built into the Jarvis Mac app).
4. **Gaming:** Windows Pro allows one session, so an RDP connection signs the PC's own screen out (apps keep
   running). If a game is in front: **warn, he decides** ("pranav-computer is in a game; connecting signs the
   PC's screen out" → Connect anyway / Cancel).
5. **Sign-in: Face ID, then Jarvis fills the Windows password** (he never types it).
6. **Keep both**: "Screen" stays the watch-only/steer live view (fine during games); "Remote Desktop" is the
   full RDP session.

7. **Sign-in uses his Microsoft account password** (checked: his account is a Microsoft account with
   "Only allow Windows Hello sign-in" on, `DevicePasswordLessBuildVersion=2`, so the Unlock secret is his PIN,
   which RDP can't use). Setup turns the Hello-only toggle off; he saves the Microsoft password once in Jarvis
   on the PC, kept DPAPI-encrypted **beside** the Unlock PIN (separate secret). PIN/Hello keep working locally.
8. **After a session: stay locked** (the PC's monitors stay on the lock screen; no `tscon` hand-back).

## Calls made for the builder (after the builder check)
- **Files:** RDP's standard drive redirection (the device's Jarvis transfer folder shows on the PC as a drive in
  Explorer; on web, Guacamole's drive with browser upload/download, ≤ 2 GB per file, deleted when the session
  ends) **plus** a "Send to PC" button that uses Holo Drop (lands in Holo Drop's PC folder).
- **Integration off really stops it:** off also switches Windows RDP off and removes the firewall rule, done by
  the existing LocalSystem helper service on the PC (pipe ACL'd to his SID, accepts only "rdp on/off") so no UAC
  prompt per toggle; the first "Set up Remote Desktop" still uses Face ID + UAC.
- **Warn on local use, not only games:** the session request also warns when the PC has had keyboard/mouse
  input in the last 2 minutes while unlocked ("Someone is using pranav-computer").
- **While a remote session runs**, Jarvis's PC-screen surfaces (island, PC Stats side-monitor window, live
  Screen share) pause/hide and come back when the PC is unlocked at the desk again.

## Goals
- One-tap Remote Desktop from the PC card (iPhone Agents card, web Agents card, Mac via Windows App).
- Full session features: clipboard both ways, files both ways (iPhone photos/files → PC, PC files → device),
  PC sound, session sized to the device and resized on rotation/window resize, keyboard with modifiers.
- Feels as smooth as the current Mac screen share for normal desktop work.

## Non-goals
- Game streaming / high-fps play (Sunshine/Moonlight was offered and not chosen).
- Multi-session hosting, other people's PCs, RDP to the Mac.
- Replacing the live screen share.

## Anti-goals (failure even if it "works")
- RDP port reachable from the open internet (only Tailscale addresses may connect).
- His Windows password stored on the server, on disk anywhere but the PC's existing DPAPI file, or in logs.
- Any surface over a fullscreen game, focus theft, or FPS cost on the PC (the standing gaming rules).
- Silently kicking a running game's session to the lock screen.

## Constraints
- PC: Windows 11 (Pro after upgrade), RTX 5070, Tailscale 100.119.223.124. Server jc-hermes: Debian 13,
  Tailscale 100.67.63.15, reaches the PC directly (~50 ms); 5 GB RAM, webui capped 2–3 GB.
- The phone may not be on Tailscale → the iPhone must work through the server.
- Admin changes on the PC go through the existing AdminRunner (Face ID on his iPhone + Windows UAC).
- New feature = a **Power integration** (`jarvis_power/`, toggle + settings on iPhone/web/Mac), per the
  project's integration architecture; off really stops it (no relay, no gateway, RDP not started by Jarvis).
- Dependencies pinned per the repo policy (FreeRDP at a release tag/commit; guacamole-common-js exact version
  vendored; Debian `guacd` package).
- iPhone ships only via `ios_app/scripts/release.sh`.

## The design (decided parts)

### 1. PC setup (Windows app, Settings → PC power → Remote Desktop)
- Detect the edition. On Home: "Needs Windows 11 Pro" + **Upgrade** button (opens `ms-settings:activation`).
- On Pro: **Set up Remote Desktop** (AdminRunner, Face ID + UAC) does, idempotently:
  - enable RDP (`fDenyTSConnections=0`), require Network Level Authentication;
  - firewall: disable the built-in "Remote Desktop" rules, add one inbound TCP/UDP 3389 rule scoped to
    `100.64.0.0/10` (Tailscale) only;
  - graphics: prefer AVC/H.264 444 and the hardware GPU for RDP sessions (the documented Group Policy
    registry values);
  - idle sessions disconnect after 30 min (policy `MaxIdleTime`); disconnected sessions stay (no log-off).
  - Status row: RDP on/off, firewall scoped yes/no, a Repair button.
- The RDP username is his Windows account (Microsoft-account sign-ins use the `MicrosoftAccount\email` form) —
  detected and shown; the password is a separate saved "Microsoft account password for Remote Desktop"
  (Settings → PC power), not the Unlock PIN. Setup also turns off "Only allow Windows Hello sign-in".

### 2. Credentials (Face ID → password; the server never stores it)
- Reuse the Unlock trust chain: the PC app holds the Remote Desktop password DPAPI-encrypted (its own file,
  beside the Unlock PIN) and trusts the iPhone's pinned signing key (`windows_app/Jarvis/Unlock/PcUnlock.cs`).
- A Remote Desktop request makes the iPhone show Face ID ("Connect to pranav-computer"); the signed yes goes
  via the server to the PC app, which verifies it and releases the password **for that one session only**:
  - **iPhone client:** the PC app encrypts the password to the iPhone's Secure-Enclave key (ECIES, P-256), so
    the server relays ciphertext only; the phone decrypts under Face ID and hands it to FreeRDP in memory.
  - **Web client:** the gateway on the server must sign in (NLA), so the PC app sends the password over the
    authenticated link to the server process for that connection, held in memory only for the connection's
    lifetime, never written or logged. Approval is still Face ID on his iPhone.
  - **Mac (Windows App):** Windows App asks once and keeps it in the Mac's own keychain (it can't take a
    password from a link) — Jarvis fills address and username.
- No saved password → "Save your Windows password in Jarvis on the PC first (Settings → PC power)".

### 3. Server (`/api/rdp`, Power integration `remote-desktop`)
- `POST /api/rdp/sessions {device_id, client}` → checks the PC is online, awake and RDP-ready; if a game is in
  front (pc-stats live `game` / game mode) returns `{"warn": "game", "game_name": …}` and the client asks him;
  `confirm: true` proceeds. Starts the Face ID approval.
- **iPhone transport: a WebSocket TCP relay** `wss …/api/rdp/relay/<session>` → TCP to the PC's Tailscale
  IP:3389. RDP's own TLS runs end to end (the server only moves bytes). Single use, bound to the session,
  closes when either side closes or after the idle timeout.
- **Web transport: Apache Guacamole** — Debian `guacd` (localhost:4822 only) + a Guacamole WebSocket tunnel
  route in the webui that does the handshake (`select rdp`, size/dpi, audio, clipboard, drive for files)
  with the in-memory credentials, then proxies.
- Integration settings: on/off, idle disconnect minutes (30), warn when a game is running (on), allow the web
  gateway (on), PC transfer folder (default `Downloads\Jarvis`).
- Audit: who connected from which client and when (no secrets), shown on the Security page.

### 4. iPhone (inside Jarvis)
- **Remote Desktop** button on the PC card (next to Screen) and as a PC tool/action (so it can be a button or
  widget action like the other PC tools).
- Embedded **FreeRDP** (Apache-2.0) built as an xcframework from a pinned release (build script under
  `ios_app/vendor/freerdp/`; large artefacts cached, not committed).
- Session view: full screen, session sized to the phone (rotation resizes the session), pinch to zoom/pan,
  touch = trackpad (tap = click, two-finger tap = right click, two-finger drag = scroll), keyboard bar (Esc,
  Tab, Ctrl, Alt, Win, arrows, Ctrl+Alt+Del, common shortcuts), system keyboard, clipboard sync (cliprdr), PC
  sound (rdpsnd), files: send photos/files to the PC transfer folder and browse/save files from it (drive
  redirection), connection-quality indicator, Disconnect. Jarvis look (JcUnified, grey controls).

### 5. Web (inside Jarvis web)
- Remote Desktop button on the web PC card → full-page session with vendored **guacamole-common-js**:
  keyboard (with a Ctrl+Alt+Del / Win button bar), clipboard sync, drag-and-drop upload and download via the
  Guacamole drive, PC sound, resize to the window, fullscreen.

### 6. Mac
- The Remote Desktop action on the Mac opens Microsoft **Windows App** with the PC's Tailscale address and
  username prefilled (an `.rdp` file or its URL scheme); if Windows App isn't installed, a link to get it.

### 7. Jarvis
- Tool `remote_desktop_status` (ready? who's connected?). Jarvis never starts a session by itself (a session
  needs his Face ID).

## Left to the builder
- FreeRDP version and build flags; iOS frame rendering approach (Metal vs CALayer).
- The Windows App launch mechanism on macOS (verify which URL scheme / `.rdp` file works).
- Exact Group Policy registry keys (verify on the PC after the upgrade).
- Relay framing/backpressure; the Guacamole tunnel inside the existing webui server.

## Order
Pro upgrade (him) → PC setup + server relay/gateway + credential chain → web client (fastest to verify) →
iPhone client → Mac launch → Jarvis tool. Each verified against the real PC.
