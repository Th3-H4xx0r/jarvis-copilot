# Photon sidecar

A tiny localhost Node service that holds the live [photon.codes](https://photon.codes)
(Spectrum) connection and exposes it to the JarvisCopilot Python gateway over HTTP.
Photon has no Python SDK yet, so this sidecar is the one process that speaks
`spectrum-ts`; the Python `PhotonAdapter` is a thin client of it.

## Why a sidecar
- Outbound: the documented proactive flow (`im.user → im.space.create → space.send`)
  is TypeScript-only.
- Inbound: a long-lived connection delivers messages on the SDK `app.messages`
  stream, so **no public Photon webhook / HMAC is needed** — the adapter just
  reads `GET /inbound`.

## Run
```bash
cd plugins/platforms/photon/sidecar
npm install
PHOTON_PROJECT_ID=... PHOTON_PROJECT_SECRET=... PHOTON_SIDECAR_TOKEN=$(openssl rand -hex 16) \
  node src/server.mjs
```
With no credentials it boots in **mock mode** (no network) — useful for wiring up
the Python side. Force mock with `PHOTON_SIDECAR_MOCK=1`.

## HTTP API (localhost only; every request needs `X-Photon-Token`)
| Method | Path       | Body                  | Returns                        |
|--------|------------|-----------------------|--------------------------------|
| GET    | `/health`  | —                     | `{ ok, connected, mock }`      |
| GET    | `/inbound` | —                     | NDJSON stream (`ready`/`message`/`heartbeat`) |
| POST   | `/send`    | `{ address, text }`   | `{ success, id }`              |
| POST   | `/typing`  | `{ address }`         | `{ success }`                  |

## Environment
| Var | Default | Meaning |
|-----|---------|---------|
| `PHOTON_PROJECT_ID` / `PHOTON_PROJECT_SECRET` | — | Photon project credentials (app.photon.codes). Absent ⇒ mock mode. |
| `PHOTON_SIDECAR_HOST` | `127.0.0.1` | Bind host (keep localhost). |
| `PHOTON_SIDECAR_PORT` | `8787` | Bind port. |
| `PHOTON_SIDECAR_TOKEN` | — | Shared secret the Python adapter sends. Set it in production. |
| `PHOTON_SIDECAR_MOCK` | `0` | Force mock mode. |
| `PHOTON_IMESSAGE_MODE` | `cloud` | Photon-hosted iMessage. |
| `PHOTON_SIDECAR_HEARTBEAT_MS` | `25000` | Idle heartbeat on `/inbound`. |

## Deploy
Run it as a systemd service (see `jarviscopilot-photon-sidecar.service`) so both the
gateway and the webui can reach it. First bring-up: confirm the `spectrum-ts` import
paths and method names in `src/photon.mjs` against the installed package version.

## Test
```bash
npm test   # node --test, MockEngine, no network
```
