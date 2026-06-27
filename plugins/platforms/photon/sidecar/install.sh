#!/usr/bin/env bash
#
# One-shot installer for the JarvisCopilot Photon (iMessage) sidecar.
#
#   ./install.sh            # install deps + generate a shared sidecar token
#   ./install.sh --service  # also install + start the systemd unit (needs root)
#
# It:
#   1. runs `npm install` in this directory,
#   2. ensures a PHOTON_SIDECAR_TOKEN exists in the SHARED JarvisCopilot .env
#      (the same file the WebUI/mobile "Photon provider" screen writes to and the
#      sidecar reads), generating one if absent — so the UI and the sidecar share
#      a token automatically and you never have to type it,
#   3. (with --service) writes/enables a systemd unit pointing at that .env.
#
# After running, finish setup in the Jarvis WebUI or mobile app
# (Settings → Photon / Code Master → Photon provider): paste PROJECT_ID /
# PROJECT_SECRET and your iMessage handle. Then restart the sidecar + gateway.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_HOME="${JARVISCOPILOT_HOME:-$HOME/.jarviscopilot}"
ENV_FILE="${PHOTON_ENV_FILE:-$ENV_HOME/.env}"

log() { printf '\033[36m[photon-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[photon-install]\033[0m %s\n' "$*" >&2; }

# 1) Node + deps -------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js (>=18) is required but not found on PATH. Install Node, then re-run."
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  warn "Node $(node -v) is too old; the sidecar needs >=18."
  exit 1
fi
log "Installing npm dependencies (spectrum-ts)…"
npm install --no-audit --no-fund

# 2) Shared sidecar token ----------------------------------------------------
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true
if grep -q '^PHOTON_SIDECAR_TOKEN=' "$ENV_FILE" 2>/dev/null; then
  log "PHOTON_SIDECAR_TOKEN already set in $ENV_FILE — leaving it."
else
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 24)"
  else
    TOKEN="$(node -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  fi
  printf 'PHOTON_SIDECAR_TOKEN=%s\n' "$TOKEN" >> "$ENV_FILE"
  log "Generated PHOTON_SIDECAR_TOKEN in $ENV_FILE (shared by the sidecar + the app)."
fi

# 3) Optional systemd service ------------------------------------------------
install_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd not found; skipping --service. Run manually: node $SCRIPT_DIR/src/server.mjs"
    return 0
  fi
  if [ "$(id -u)" != "0" ]; then
    warn "--service needs root (writing /etc/systemd/system). Re-run with sudo, or start manually."
    return 1
  fi
  local node_bin unit
  node_bin="$(command -v node)"
  unit=/etc/systemd/system/jarviscopilot-photon-sidecar.service
  log "Writing $unit"
  cat > "$unit" <<UNIT
[Unit]
Description=JarvisCopilot Photon (Spectrum) sidecar
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
# Shared JarvisCopilot env — optional (-) so a missing file doesn't fail the unit.
EnvironmentFile=-$ENV_FILE
ExecStart=$node_bin src/server.mjs
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable jarviscopilot-photon-sidecar >/dev/null 2>&1 || true
  # restart (not just enable --now) so an already-running sidecar reloads new code.
  systemctl restart jarviscopilot-photon-sidecar
  log "Installed + (re)started jarviscopilot-photon-sidecar."
}

if [ "${1:-}" = "--service" ]; then
  install_service
fi

log "Done."
log "Next: in the Jarvis WebUI (Code Master → Photon provider) or mobile"
log "(Settings → Photon), paste PROJECT_ID / PROJECT_SECRET + your iMessage handle."
if [ "${1:-}" != "--service" ]; then
  log "Start the sidecar:  node $SCRIPT_DIR/src/server.mjs"
  log "(or re-run with --service to install it as a systemd unit)"
fi
