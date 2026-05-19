#!/usr/bin/env bash
# ============================================================================
# JarvisCopilot Desktop Client — macOS installer
# ============================================================================
# Per-user install under ~/Library/Application Support/jc-client,
# `jc-client` shim in ~/.local/bin, LaunchAgent for autostart, and
# kicks off the pairing dialog at the end.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-mac.sh | bash
# ============================================================================
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/Th3-H4xx0r/jarvis-copilot.git"
INSTALL_DIR="${JC_CLIENT_DIR:-$HOME/Library/Application Support/jc-client}"
BRANCH="${JC_CLIENT_BRANCH:-main}"
REPO_URL="${JC_CLIENT_REPO:-$REPO_URL_DEFAULT}"

info()  { printf '\033[36m[jc-client install]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[jc-client install]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[jc-client install]\033[0m %s\n' "$*"; }
die()   { printf '\033[31m[jc-client install]\033[0m %s\n' "$*" >&2; exit 1; }

# --- prereqs ----------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git not on PATH. Install Xcode CLI tools first."
PY=""
for cand in python3.13 python3.12 python3.11 python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && \
       "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        PY="$(command -v "$cand")"
        break
    fi
done
[[ -z "$PY" ]] && die "Python 3.11+ required (brew install python@3.13)"
info "Using Python: $PY"

# --- source -----------------------------------------------------------------
SRC_DIR="$INSTALL_DIR/src"
mkdir -p "$INSTALL_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
    info "Updating $SRC_DIR"
    (cd "$SRC_DIR" && git fetch origin "$BRANCH" --quiet && git pull --ff-only origin "$BRANCH" >/dev/null)
else
    info "Cloning $REPO_URL → $SRC_DIR"
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
info "Installing jarviscopilot-client ..."
"$VENV_PY" -m pip install -e "$SRC_DIR/desktop_client" -q --progress-bar off

# --- PATH shim --------------------------------------------------------------
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$VENV_DIR/bin/jc-client" "$BIN_DIR/jc-client"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not on PATH. Add it (zsh):"
        warn "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        ;;
esac

# --- LaunchAgent ------------------------------------------------------------
# Runs the tray (which auto-spawns the service). LaunchAgents run on
# user login. KeepAlive ensures we resurrect after crashes.
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.jarviscopilot.client.plist"
mkdir -p "$PLIST_DIR"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jarviscopilot.client</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV_DIR/bin/jc-client</string>
        <string>tray</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.jarviscopilot-client/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.jarviscopilot-client/logs/launchd.err.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# Re-load the agent so a changed venv path takes effect.
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST"

ok "Installed at $INSTALL_DIR"
echo
echo "LaunchAgent enabled — the tray will auto-start on login."
echo
echo "Pair this device now:"
echo "  jc-client pair"
echo
echo "Logs: $HOME/.jarviscopilot-client/logs/client.log"
