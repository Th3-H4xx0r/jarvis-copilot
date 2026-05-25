#!/usr/bin/env bash
# ============================================================================
# JarvisCopilot Installer (Linux / macOS / WSL2)
# ============================================================================
# Clones the JarvisCopilot fork, creates a local Python venv, installs JarvisCopilot
# core + voice extras + piper-tts + webui deps, and generates a self-signed
# TLS cert so the voice tab works over LAN.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/install-jarviscopilot.sh | bash
#
# Or with options:
#   curl -fsSL ... | bash -s -- --dir /opt/jarviscopilot --branch dev
#
# Re-running this is SAFE and IDEMPOTENT:
#   - Updates code with `git pull --ff-only` (refuses to discard local commits)
#   - Re-creates the venv ONLY if it's missing
#   - pip install is naturally idempotent — already-installed packages skip
#   - TLS cert is regenerated ONLY if missing or expired
#   - NEVER touches ~/.jarviscopilot/ contents — your config.yaml, SOUL.md, skills/,
#     cron jobs, sessions, auth.json, and credential pool are preserved
# ============================================================================

set -euo pipefail

REPO_URL_DEFAULT="https://github.com/Th3-H4xx0r/jarvis-copilot.git"
INSTALL_DIR_DEFAULT="${JARVISCOPILOT_DIR:-$HOME/JarvisCopilot}"
BRANCH_DEFAULT="main"

REPO_URL="$REPO_URL_DEFAULT"
INSTALL_DIR="$INSTALL_DIR_DEFAULT"
BRANCH="$BRANCH_DEFAULT"
SKIP_PIPER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)     INSTALL_DIR="$2"; shift 2 ;;
        --branch)  BRANCH="$2"; shift 2 ;;
        --repo)    REPO_URL="$2"; shift 2 ;;
        --skip-piper) SKIP_PIPER=true; shift ;;
        -h|--help)
            sed -n '2,/^# =\+/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2 ;;
    esac
done

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
info()  { printf '%s[install]%s %s\n' "$CYAN" "$NC" "$*"; }
ok()    { printf '%s[install]%s %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[install]%s %s\n' "$YELLOW" "$NC" "$*"; }
die()   { printf '%s[install]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

# --- Prerequisites ----------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git not found on PATH. Install git first."

PY=""
for cand in python3.13 python3.12 python3.11 python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
        # Need >= 3.11
        if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
            PY="$(command -v "$cand")"
            break
        fi
    fi
done
[[ -z "$PY" ]] && die "Python 3.11+ not found. Install Python 3.11 or newer, then re-run."
info "Using Python: $PY"

# --- Clone or fast-forward update -------------------------------------------
# git pull --ff-only refuses to merge or rebase, so a local commit on this
# branch is preserved. The script exits with an error if the user has
# in-progress local work that conflicts with upstream — better than silently
# overwriting their changes.
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing checkout at $INSTALL_DIR ..."
    (
        cd "$INSTALL_DIR"
        # Fetch first so we can compare local vs remote without networking inside pull
        git fetch origin "$BRANCH" --quiet
        local_sha="$(git rev-parse HEAD)"
        remote_sha="$(git rev-parse "origin/$BRANCH")"
        if [[ "$local_sha" == "$remote_sha" ]]; then
            info "Already at $remote_sha -- no code changes."
        else
            info "Local: $local_sha"
            info "Remote: $remote_sha"
            git pull --ff-only origin "$BRANCH" || die "git pull --ff-only failed. Local commits diverge from origin/$BRANCH. Resolve manually."
        fi
    )
else
    info "Cloning $REPO_URL (branch $BRANCH) -> $INSTALL_DIR"
    git clone --branch "$BRANCH" --single-branch --quiet "$REPO_URL" "$INSTALL_DIR" || die "git clone failed"
fi

cd "$INSTALL_DIR"

# Defensive: ensure shell scripts have the executable bit. Git stores the
# exec bit, but some filesystems (vfat, exfat, certain network shares) drop
# it on checkout. Also covers users who tar-extracted instead of cloning.
chmod +x scripts/*.sh 2>/dev/null || true

# --- Stop any running JarvisCopilot / JarvisCopilot instances ---------------------
# Idempotent best-effort shutdown so the rest of the installer (pip install,
# systemd unit rewrite, tray re-launch) doesn't fight a process holding the
# venv's interpreter or port 8787.
info "Stopping any running JarvisCopilot / JarvisCopilot instances ..."

SUDO_STOP=""
if [[ "$EUID" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO_STOP="sudo -n"
fi

if command -v systemctl >/dev/null 2>&1; then
    for unit in jarviscopilot-webui.service jarviscopilot-webui.service \
                jarviscopilot-gateway.service jarviscopilot-gateway.service; do
        if [[ -n "$SUDO_STOP" ]]; then
            $SUDO_STOP systemctl stop "$unit" >/dev/null 2>&1 || true
        else
            systemctl stop "$unit" >/dev/null 2>&1 || true
        fi
    done
fi

# Collect PIDs of anything still alive: port 8787 listener + gateway loop.
STOP_PIDS=""
if command -v ss >/dev/null 2>&1; then
    STOP_PIDS+=" $(ss -tlnpH 'sport = :8787' 2>/dev/null \
        | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+' || true)"
elif command -v lsof >/dev/null 2>&1; then
    STOP_PIDS+=" $(lsof -iTCP:8787 -sTCP:LISTEN -Pn -t 2>/dev/null || true)"
fi
if command -v pgrep >/dev/null 2>&1; then
    STOP_PIDS+=" $(pgrep -f 'jarviscopilot_cli\.main +gateway +run' 2>/dev/null || true)"
fi
STOP_PIDS="$(printf '%s\n' $STOP_PIDS | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)"

if [[ -n "${STOP_PIDS// /}" ]]; then
    info "Sending SIGTERM to existing PID(s): $STOP_PIDS"
    for pid in $STOP_PIDS; do
        kill "$pid" 2>/dev/null || ($SUDO_STOP kill "$pid" 2>/dev/null || true)
    done
    sleep 2
    for pid in $STOP_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || ($SUDO_STOP kill -9 "$pid" 2>/dev/null || true)
        fi
    done
fi

# --- venv -------------------------------------------------------------------
VENV_DIR="$INSTALL_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"
if [[ ! -x "$VENV_PY" ]]; then
    info "Creating venv at $VENV_DIR ..."
    "$PY" -m venv "$VENV_DIR"
fi

# --- Install JarvisCopilot core + voice extras + webui deps -----------------------
# `pip install -e .[all,voice,edge-tts]` is idempotent — pip checks each
# dist's installed version against the requirement and skips if satisfied.
# Existing user state in ~/.jarviscopilot/ is never touched by pip.
# Quiet flags: -q hides "Requirement already satisfied" spam; the progress
# bar still appears on actual downloads. --no-input refuses to prompt for
# anything so the script stays unattended.
PIP_QUIET=(-q --progress-bar off --no-input)

info "Installing core + voice extras (this can take a few minutes on first run) ..."
"$VENV_PY" -m pip install --upgrade pip "${PIP_QUIET[@]}" || die "pip upgrade failed"
"$VENV_PY" -m pip install -e ".[all,voice,edge-tts]" "${PIP_QUIET[@]}" || die "pip install failed"

info "Installing webui dependencies ..."
"$VENV_PY" -m pip install -r webui/requirements.txt "${PIP_QUIET[@]}" || die "webui requirements install failed"

if [[ "$SKIP_PIPER" != "true" ]]; then
    info "Installing piper-tts (for JARVIS voice) ..."
    "$VENV_PY" -m pip install piper-tts "${PIP_QUIET[@]}" || warn "piper-tts install failed -- JARVIS personality will need a manual 'pip install piper-tts' later."
fi

# Touch the install marker so the launch script skips re-install on next launch.
mkdir -p "$VENV_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$VENV_DIR/.webui-installed"

# --- Merge shipped personalities into ~/.jarviscopilot/config.yaml ----------------
# Idempotent — adds entries (e.g. jarvis-mcu) only when missing, never
# overwrites the user's existing personalities or other config keys.
# Writes a timestamped backup before any change, so a botched merge is
# recoverable from ~/.jarviscopilot/config.yaml.merge-bak.<timestamp>.
info "Merging shipped personalities into ~/.jarviscopilot/config.yaml ..."
"$VENV_PY" "$INSTALL_DIR/installer/merge-personalities.py" || warn "personality merge failed (non-fatal)"

# --- TLS cert (idempotent — only generates if missing/expired) -------------
info "Ensuring self-signed TLS cert for the webui ..."
"$VENV_PY" - <<'PY' || warn "TLS cert generation failed; you can still run the webui in HTTP mode."
import sys
sys.path.insert(0, 'webui')
try:
    from api.tls import ensure_self_signed_cert, cert_fingerprint_sha256
    cert_path, key_path = ensure_self_signed_cert()
    print(f"  cert: {cert_path}")
    print(f"  key:  {key_path}")
    print(f"  fingerprint: {cert_fingerprint_sha256(cert_path)}")
except Exception as e:
    raise SystemExit(f"cert generation failed: {e}")
PY

# --- PATH symlinks (so `jarviscopilot` and `jarviscopilot` work from any shell) ---
# Linux convention: drop a symlink into /usr/local/bin (already on every
# distro's default PATH). If we can't write there (non-root + no sudo NOPASSWD),
# fall back to ~/.local/bin and tell the user how to add it to their PATH.
LINK_DIR=""
if [[ -w /usr/local/bin ]]; then
    LINK_DIR=/usr/local/bin
elif sudo -n true 2>/dev/null && sudo -n test -w /usr/local/bin 2>/dev/null; then
    LINK_DIR=/usr/local/bin
else
    LINK_DIR="$HOME/.local/bin"
    mkdir -p "$LINK_DIR"
fi
_link() {
    local src="$1" dest="$2"
    if [[ "$LINK_DIR" == "/usr/local/bin" && ! -w /usr/local/bin ]]; then
        sudo -n ln -sf "$src" "$dest" 2>/dev/null || ln -sf "$src" "$dest"
    else
        ln -sf "$src" "$dest"
    fi
}
_link "$VENV_DIR/bin/jarviscopilot" "$LINK_DIR/jarviscopilot"
_link "$VENV_DIR/bin/hermes"        "$LINK_DIR/hermes"
info "CLI commands linked at $LINK_DIR/{jarviscopilot,jarviscopilot}"
if [[ "$LINK_DIR" != "/usr/local/bin" ]]; then
    case ":$PATH:" in
        *":$LINK_DIR:"*) ;;
        *)
            warn "$LINK_DIR is not on your PATH. Add it with:"
            warn "  echo 'export PATH=\"$LINK_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
            ;;
    esac
fi

# --- systemd unit (auto-start, survives reboot) ----------------------------
# Only on Linux with systemd available. Idempotent — we always rewrite the
# unit file (matches whatever this script knows about the install path) and
# enable+restart so future updates pick up code changes after `git pull`.
SERVICE_INSTALLED=false
if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
    info "Installing jarviscopilot-webui.service (systemd) ..."
    SUDO=""
    if [[ "$EUID" -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then SUDO="sudo -n"
        else warn "Skipping systemd setup -- need passwordless sudo. Run the launcher manually with: $INSTALL_DIR/scripts/launch-webui.sh"; fi
    fi
    if [[ "$EUID" -eq 0 || -n "$SUDO" ]]; then
        UNIT="/etc/systemd/system/jarviscopilot-webui.service"
        $SUDO tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=JarvisCopilot WebUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=$INSTALL_DIR
Environment=JARVISCOPILOT_PAIRING_REQUIRED=1
ExecStart=$INSTALL_DIR/scripts/launch-webui.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF
        $SUDO systemctl daemon-reload
        $SUDO systemctl enable jarviscopilot-webui.service >/dev/null 2>&1
        $SUDO systemctl restart jarviscopilot-webui.service
        SERVICE_INSTALLED=true
        ok "Service enabled and started. View logs with: journalctl -u jarviscopilot-webui -f"

        # Restart the gateway too if it's installed. The gateway (separate
        # from the webui) is what ticks the cron scheduler AND runs the
        # messaging platforms — server.py / launch-webui.sh do NOT. The
        # stop-loop near the top of this script stopped it, so without this
        # re-running the installer to deploy would silently kill cron jobs +
        # messaging until a manual `jarviscopilot gateway restart`. We only
        # restart a unit that already exists (we never create it here), and
        # check both system and user scope so non-root setups are covered.
        if $SUDO systemctl cat jarviscopilot-gateway.service >/dev/null 2>&1; then
            if $SUDO systemctl restart jarviscopilot-gateway.service >/dev/null 2>&1; then
                ok "Restarted jarviscopilot-gateway.service (cron scheduler + messaging)."
            else
                warn "jarviscopilot-gateway.service exists but failed to restart -- run: jarviscopilot gateway restart"
            fi
        elif systemctl --user cat jarviscopilot-gateway.service >/dev/null 2>&1; then
            if systemctl --user restart jarviscopilot-gateway.service >/dev/null 2>&1; then
                ok "Restarted jarviscopilot-gateway.service (user scope; cron + messaging)."
            else
                warn "user jarviscopilot-gateway.service failed to restart -- run: jarviscopilot gateway restart"
            fi
        fi
    fi
fi

# --- Detect the LAN URL to print --------------------------------------------
LAN_IP=""
if command -v hostname >/dev/null 2>&1; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "$LAN_IP" ]]; then
    LAN_IP="$("$VENV_PY" - <<'PY' 2>/dev/null
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0]); s.close()
except Exception:
    pass
PY
)"
fi
[[ -z "$LAN_IP" ]] && LAN_IP="<your-host-ip>"

# --- Final status -----------------------------------------------------------
ok "JarvisCopilot installed at $INSTALL_DIR"
echo
echo "Your existing data in ~/.jarviscopilot/ (config, skills, cron jobs, sessions,"
echo "credentials, memory) was NOT touched by this install."
echo
if [[ "$SERVICE_INSTALLED" == "true" ]]; then
    sleep 3   # give the service a moment to bind the port
    if ss -tln 2>/dev/null | grep -q ":8787"; then
        echo "${GREEN}WebUI is live:${NC}"
        echo "  Local: https://localhost:8787"
        echo "  LAN:   https://$LAN_IP:8787"
        echo
        echo "Logs: journalctl -u jarviscopilot-webui -f"
    else
        warn "Service started but port 8787 isn't bound yet. Check: journalctl -u jarviscopilot-webui -n 50"
    fi
else
    echo "Start the WebUI manually:"
    echo "  $INSTALL_DIR/scripts/launch-webui.sh"
fi
echo
echo "${CYAN}First-time auth (if you haven't already):${NC}"
echo "  jarviscopilot auth add openai-codex --type oauth --no-browser"
echo "  jarviscopilot model openai-codex"
echo
echo "Browser will warn about the self-signed cert -- tap Advanced -> Proceed."
echo "Re-run this installer anytime to update code. Config and data stay put."
