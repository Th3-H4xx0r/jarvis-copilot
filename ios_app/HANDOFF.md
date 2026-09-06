# JarvisCopilot — session handoff

Written 2026-09-01. Everything below is the state at the end of the first build session.

## What this is

An iOS/macOS app that drives a **VSITOO S1 Pro** UV-C self-sterilising water bottle over
BLE, and exposes it to **JarvisCopilot** as a paired device so the agent can read and
control it.

The BLE protocol was reverse-engineered from the stock VSITOO Android app
(`VSITOO_1.0.141_APKPure`). It's a DCloud/uni-app hybrid, so the protocol lives in
bundled JavaScript, not the DEX. Full byte-level reference in **`PROTOCOL.md`**.

## Current state

**Working and verified**

- BLE discovery, connect, and the full command set against the real bottle.
- The 3D model — a procedural surface of revolution, no asset files, plus the
  sterilise animation (lid unscrews, UV beam, camera crane).
- Pairing with JarvisCopilot over the device bridge, including QR scan.
- The app registers 10 `bottle_*` skills; they show in the WebUI, and now persist
  while the app is backgrounded.
- APNs: a real silent push to the phone returns `{'ok': True}` from Apple.

**Not working yet — the one open thread**

Jarvis can see the skills but a backgrounded invoke times out: *"The wearable app did
not respond before the command timed out."*

The chain is: agent → `invoke_skill` → no live WS → silent push → app wakes →
`drainQueue` → `/api/devices/mobile/poll` → BLE → result posted back. Everything up to
"app wakes" is verified. What isn't known is whether the push actually reaches the phone.

To find out, Settings → Jarvis Copilot now shows a **Last wake** row:

| Shows | Means |
|---|---|
| *nothing* | push never arrived — APNs delivery or iOS throttling |
| `woke, queue empty` | push arrived, nothing queued (timing race) |
| `poll failed` | push arrived, server unreachable |
| `running N` → `delivered N` | full path worked |

**If the row is absent**, check Background App Refresh is enabled for the app, and that
it wasn't force-quit — iOS won't deliver silent pushes to a swiped-away app.

## Architecture

```
Jarvis agent ──HTTP──▶ webui (/api/devices/skills/invoke)
                          │
                    live WS? ──yes──▶ device bridge WS ──▶ app
                          │
                          no
                          ▼
                  silent APNs push ──▶ app wakes ──▶ /mobile/poll
                                                        │
                                                        ▼
                                              CoreBluetooth ──▶ bottle
```

The device framework in the app is deliberately generic: `WearableDevice` declares a
command catalogue and a state snapshot, `VsitooS1Pro` implements it, `DeviceRegistry`
routes. Adding a second product means conforming one type — the bridge and UI don't
change.

## Non-obvious things that cost time

- **`aps-environment` cannot be forced.** Setting `production` in the entitlements file
  *silently signs as `development`* when the profile is a development one. Verify with
  `codesign -d --entitlements :-` on the built app, never by reading the plist.
- **A wildcard provisioning profile cannot carry push.** Getting APNs required switching
  from hand-signing to Xcode automatic signing, which mints a real App ID.
- **`UIBackgroundModes: [bluetooth-central]` alone does nothing.** CoreBluetooth only
  survives backgrounding when the central is created with
  `CBCentralManagerOptionRestoreIdentifierKey`.
- **The `(XXXXXXXXXX)` in a certificate's name is the certificate ID, not the team ID.**
  The team is the OU field — `VY5CNF8734`. Using the wrong one fails as
  "No Account for Team".
- **An APNs `.p8` is team-scoped, not app-scoped.** One key signs for every bundle ID
  under the team; only the `apns-topic` header differs. Apple *does* now let a key be
  restricted to one environment, which is a separate thing.
- **`SCNVector3` takes `CGFloat` on macOS and `Float` on iOS.** Mixed arithmetic compiles
  for one platform and not the other.
- **The bottle's status byte 6 is a countdown**, not percent-complete. Confirmed live:
  94 at 8s elapsed, 86 at 15s.
- **`plutil -insert com.apple.security.foo`** treats dots as keypath separators and
  silently writes nothing. Always verify the file afterwards.

## Server

Runs on `hermes` as root. Live checkout `/root/JarvisCopilot`, service
`jarviscopilot-webui.service`, state dir `/root/.jarviscopilot/webui/`. Behind a
Cloudflare tunnel — pairing hands the app a CF Access service token, which it stores and
sends on every request.

Deploy: `git pull origin main && systemctl restart jarviscopilot-webui.service`.

## Deploying the app

`./deploy-iphone.sh` — builds with automatic signing, verifies `aps-environment` is
present, installs and launches. Xcode has an Apple ID registered now, so this works
without manual profile juggling.

## Known gaps

- **This project is not under version control.** No git repo at all. The JarvisCopilot
  side is committed and pushed; none of the app is.
- `bottle_raw_command`, `aiSelfCleanTimed`, `aiSelfCleanPermanent` and
  `setAutoSteriliseTimes` are implemented but unreferenced by the UI — kept because they
  encode recovered opcodes.
- The macOS target builds but has never been run.
