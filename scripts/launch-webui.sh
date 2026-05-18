#!/usr/bin/env bash
# Launch the Hermes WebUI bound to 0.0.0.0 so other machines on your network
# can reach it. First run installs Hermes core + webui dependencies into a
# local .venv at the repo root; later runs skip the install step.
#
# Usage:
#   scripts/launch-webui.sh                    # default port 8787
#   HERMES_WEBUI_PORT=9001 scripts/launch-webui.sh
#
# Stop the server with Ctrl+C.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"
WEBUI_DIR="${REPO_ROOT}/webui"

if [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "win32" ]]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
else
    VENV_PYTHON="${VENV_DIR}/bin/python"
fi

info()  { printf '\033[36m[launch-webui]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[launch-webui]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[launch-webui]\033[0m %s\n' "$*"; }
die()   { printf '\033[31m[launch-webui]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- venv ------------------------------------------------------------
if [[ ! -x "${VENV_PYTHON}" ]]; then
    info "Creating Python venv at ${VENV_DIR} ..."
    PY="$(command -v python3 || command -v python || true)"
    [[ -z "${PY}" ]] && die "Python 3.11+ is required (not found on PATH)."
    "${PY}" -m venv "${VENV_DIR}"
fi

# ---- install (idempotent — pip is fast on no-op) ---------------------
# The marker file is touched after a successful install so subsequent runs
# skip the slow pip step. Delete `.venv/.webui-installed` to force a refresh.
#
# `pip install -e <path>[extras]` ALWAYS installs from the local path (the
# leading `-e` and the path argument both force pip to skip PyPI for this
# project — only its transitive deps come from PyPI). We additionally
# verify that hermes-agent's resolved install location is this repo root
# before launching the server, so a stale PyPI install in this venv (or a
# typo'd path) can't silently take over.
MARKER="${VENV_DIR}/.webui-installed"
if [[ ! -f "${MARKER}" ]]; then
    info "Installing Hermes core from LOCAL path: ${REPO_ROOT}"
    info "  (pip flag: -e ${REPO_ROOT}[all,voice,edge-tts] -- editable, no PyPI lookup for hermes-agent)"
    # [voice] = faster-whisper + sounddevice + numpy (STT)
    # [edge-tts] = Microsoft Edge neural TTS (default Hermes TTS provider)
    # Both are intentionally excluded from [all] by Hermes (lazy-install
    # design); the webui needs them up-front so the voice tab works on
    # first boot without a runtime dependency download.
    "${VENV_PYTHON}" -m pip install --upgrade pip >/dev/null
    "${VENV_PYTHON}" -m pip install -e "${REPO_ROOT}[all,voice,edge-tts]"

    info "Installing webui dependencies ..."
    "${VENV_PYTHON}" -m pip install -r "${WEBUI_DIR}/requirements.txt"

    # piper-tts powers the JARVIS personality's neural TTS voice. Pull it in
    # up-front so users picking JARVIS in Settings dont have to wait for a
    # runtime pip install (Hermes has a lazy-install path but its slow).
    info "Installing piper-tts (for JARVIS voice) ..."
    "${VENV_PYTHON}" -m pip install piper-tts || warn "piper-tts install failed -- JARVIS voice will require a manual install"

    date -u +%Y-%m-%dT%H:%M:%SZ > "${MARKER}"
    ok "Install complete. Delete ${MARKER} to force a refresh next run."
else
    info "Skipping install (marker present). Delete ${MARKER} to force a refresh."
fi

# ---- VERIFY hermes-agent is the LOCAL editable install --------------
# Run on every launch — catches the case where the marker exists but the
# venv has somehow ended up with a PyPI-installed hermes-agent instead.
SHOW_OUTPUT="$("${VENV_PYTHON}" -m pip show hermes-agent 2>&1 || true)"
if ! grep -q '^Name: hermes-agent' <<<"${SHOW_OUTPUT}"; then
    die "hermes-agent is not installed in ${VENV_DIR}. Delete ${MARKER} and rerun."
fi
# Modern pip (>= 21.3) reports "Editable project location" for `-e` installs;
# fall back to "Location:" for older pip versions, where the egg-link points
# to the source dir.
RESOLVED="$(grep -m1 '^Editable project location:' <<<"${SHOW_OUTPUT}" | sed 's/^Editable project location: //')"
if [[ -z "${RESOLVED}" ]]; then
    RESOLVED="$(grep -m1 '^Location:' <<<"${SHOW_OUTPUT}" | sed 's/^Location: //')"
fi
# Canonicalize both sides — readlink -f is GNU-only; fall back to python.
canon() {
    if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
        readlink -f "$1"
    else
        "${VENV_PYTHON}" -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
    fi
}
EXPECTED_CANON="$(canon "${REPO_ROOT}")"
RESOLVED_CANON="$(canon "${RESOLVED}")"
if [[ "${EXPECTED_CANON}" != "${RESOLVED_CANON}" ]]; then
    echo
    echo "[launch-webui] FATAL: hermes-agent in the venv is NOT this monorepo." >&2
    echo "  Expected: ${EXPECTED_CANON}" >&2
    echo "  Found:    ${RESOLVED_CANON}" >&2
    echo "  Delete   ${VENV_DIR}   and rerun this script." >&2
    exit 1
fi
ok "Verified: hermes-agent resolves to LOCAL path ${RESOLVED}"

# ---- TLS cert (self-signed; required so browsers allow getUserMedia) -
# Browsers refuse mic / camera / clipboard / WebRTC on plain HTTP for any
# origin that isn't localhost. We generate a self-signed cert with SANs
# covering all local IPv4 addresses so the voice tab works from a phone or
# any device on the LAN. First boot tap "Advanced → Proceed" once; the
# cert is stable across restarts.
info "Ensuring TLS cert in ~/.hermes/webui-tls/ ..."
TLS_PAIR="$("${VENV_PYTHON}" -c "
import sys
sys.path.insert(0, '${WEBUI_DIR}')
from api.tls import ensure_self_signed_cert, cert_fingerprint_sha256
cp, kp = ensure_self_signed_cert()
print(cp); print(kp); print(cert_fingerprint_sha256(cp))
")"
[[ -z "${TLS_PAIR}" ]] && die "Failed to ensure TLS cert"
export HERMES_WEBUI_TLS_CERT="$(sed -n 1p <<<"${TLS_PAIR}")"
export HERMES_WEBUI_TLS_KEY="$(sed -n 2p <<<"${TLS_PAIR}")"
TLS_FINGERPRINT="$(sed -n 3p <<<"${TLS_PAIR}")"
ok "Using cert ${HERMES_WEBUI_TLS_CERT}"
info "Cert SHA-256: ${TLS_FINGERPRINT}"

# ---- port + LAN IP detection -----------------------------------------
PORT="${HERMES_WEBUI_PORT:-8787}"

# Best-effort: the primary outbound IPv4 by opening a UDP socket to a
# well-known address — kernel picks the route but no packet is sent.
LAN_IP="$( \
    "${VENV_PYTHON}" - <<'PY' 2>/dev/null
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0])
    s.close()
except Exception:
    pass
PY
)"
[[ -z "${LAN_IP}" ]] && LAN_IP="<your-host-ip>"

# ---- env for the server ---------------------------------------------
export HERMES_WEBUI_HOST=0.0.0.0
export HERMES_WEBUI_PORT="${PORT}"
# Tell the webui's voice routes (api/voice.py) and bootstrap discovery
# where to find Hermes core. The voice module's own _ensure_hermes_on_path()
# adds this too, but setting PYTHONPATH up front avoids import-order surprises.
export PYTHONPATH="${REPO_ROOT}"
export HERMES_WEBUI_AGENT_DIR="${REPO_ROOT}"

# ---- banner ---------------------------------------------------------
echo
echo "================================================================"
ok " Hermes WebUI starting on 0.0.0.0:${PORT}  (TLS)"
ok " Local:   https://localhost:${PORT}"
ok " LAN:     https://${LAN_IP}:${PORT}"
echo "================================================================"
echo
warn "First connection: browser shows 'Not Private' — tap Advanced -> Proceed."

if command -v ufw >/dev/null 2>&1; then
    warn "If UFW is on, allow the port:  sudo ufw allow ${PORT}/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    warn "If firewalld is on:  sudo firewall-cmd --add-port=${PORT}/tcp"
fi

# ---- run -----------------------------------------------------------
cd "${WEBUI_DIR}"
exec "${VENV_PYTHON}" server.py
