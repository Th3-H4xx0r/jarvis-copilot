#!/usr/bin/env bash
# ============================================================================
# JarvisCopilot Desktop Client — Linux installer
# ============================================================================
# Builds a per-user venv under ~/.local/share/jc-client, drops a
# `jc-client` symlink in ~/.local/bin, installs a systemd --user unit,
# and runs the first-time pairing dialog.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-linux.sh | bash
#
# Idempotent: re-running upgrades the venv contents and refreshes the
# systemd unit. Existing pairing creds in ~/.jarviscopilot-client/
# are NOT touched.
# ============================================================================
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/Th3-H4xx0r/jarvis-copilot.git"
INSTALL_DIR="${JC_CLIENT_DIR:-$HOME/.local/share/jc-client}"
BRANCH="${JC_CLIENT_BRANCH:-main}"
REPO_URL="${JC_CLIENT_REPO:-$REPO_URL_DEFAULT}"

info()  { printf '\033[36m[jc-client install]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[jc-client install]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[jc-client install]\033[0m %s\n' "$*"; }
die()   { printf '\033[31m[jc-client install]\033[0m %s\n' "$*" >&2; exit 1; }

# --- prereqs ----------------------------------------------------------------
command -v git    >/dev/null 2>&1 || die "git not on PATH"
PY=""
for cand in python3.13 python3.12 python3.11 python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && \
       "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        PY="$(command -v "$cand")"
        break
    fi
done
[[ -z "$PY" ]] && die "Python 3.11+ required"
info "Using Python: $PY"

# Pair UI prerequisites. We prefer pywebview (modern dark theme matching
# the webui) and fall back to Tk. Either way we want at least one of
# them runnable; the user can re-run the installer after `apt install`.
if ! "$PY" -c 'import tkinter' 2>/dev/null; then
    warn "tkinter not available — fallback pair dialog won't work without it:"
    warn "  Debian/Ubuntu: sudo apt install python3-tk"
    warn "  Fedora:        sudo dnf install python3-tkinter"
    warn "  Arch:          sudo pacman -S tk"
fi
# pywebview on Linux needs the native WebKit2GTK runtime. We can't
# `pip install` it — it's a system library.
if ! pkg-config --exists webkit2gtk-4.1 2>/dev/null && \
   ! pkg-config --exists webkit2gtk-4.0 2>/dev/null; then
    warn "WebKit2GTK not detected — the modern pair UI will fall back to Tk."
    warn "For the native pywebview UI, install:"
    warn "  Debian/Ubuntu: sudo apt install gir1.2-webkit2-4.1 libwebkit2gtk-4.1-dev"
    warn "  Fedora:        sudo dnf install webkit2gtk4.1-devel"
    warn "  Arch:          sudo pacman -S webkit2gtk-4.1"
fi

# --- source -----------------------------------------------------------------
SRC_DIR="$INSTALL_DIR/src"
if [[ -d "$SRC_DIR/.git" ]]; then
    info "Updating $SRC_DIR"
    (cd "$SRC_DIR" && git fetch origin "$BRANCH" --quiet && git pull --ff-only origin "$BRANCH" >/dev/null)
else
    info "Cloning $REPO_URL → $SRC_DIR"
    mkdir -p "$INSTALL_DIR"
    git clone --branch "$BRANCH" --single-branch --quiet "$REPO_URL" "$SRC_DIR"
fi

# --- venv -------------------------------------------------------------------
VENV_DIR="$INSTALL_DIR/.venv"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    info "Creating venv"
    "$PY" -m venv "$VENV_DIR"
fi
VENV_PY="$VENV_DIR/bin/python"
"$VENV_PY" -m pip install --upgrade pip -q --progress-bar off
info "Installing jarviscopilot-client (this can take a minute) ..."
"$VENV_PY" -m pip install -e "$SRC_DIR/desktop_client" -q --progress-bar off

# --- PATH symlink -----------------------------------------------------------
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$VENV_DIR/bin/jc-client" "$BIN_DIR/jc-client"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not on PATH. Add to ~/.bashrc:"
        warn "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        ;;
esac

# --- systemd --user unit ----------------------------------------------------
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
UNIT_FILE="$UNIT_DIR/jc-client.service"
cat > "$UNIT_FILE" <<UNITEOF
[Unit]
Description=JarvisCopilot desktop client
After=network-online.target graphical-session.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/jc-client start --no-tray
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNITEOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable jc-client.service >/dev/null 2>&1 || true
    # We do NOT start it yet — the user pairs first, then runs `jc-client restart`.
fi

ok "Installed at $INSTALL_DIR"
echo
echo "Next steps:"
echo "  1. Pair this device:"
echo "       jc-client pair"
echo "  2. Start the service:"
echo "       systemctl --user start jc-client"
echo "  3. View logs:"
echo "       jc-client logs --follow"
