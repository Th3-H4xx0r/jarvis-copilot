#!/usr/bin/env bash
# ============================================================================
# JarvisCopilot Installer (Linux / macOS / WSL2)
# ============================================================================
# Clones the JarvisCopilot fork, creates a local Python venv, installs Hermes
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
#   - NEVER touches ~/.hermes/ contents — your config.yaml, SOUL.md, skills/,
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
            info "Already at $remote_sha — no code changes."
        else
            info "Local: $local_sha"
            info "Remote: $remote_sha"
            git pull --ff-only origin "$BRANCH" || die "git pull --ff-only failed. Local commits diverge from origin/$BRANCH. Resolve manually."
        fi
    )
else
    info "Cloning $REPO_URL (branch $BRANCH) -> $INSTALL_DIR"
    git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$INSTALL_DIR" || die "git clone failed"
fi

cd "$INSTALL_DIR"

# --- venv -------------------------------------------------------------------
VENV_DIR="$INSTALL_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"
if [[ ! -x "$VENV_PY" ]]; then
    info "Creating venv at $VENV_DIR ..."
    "$PY" -m venv "$VENV_DIR"
fi

# --- Install Hermes core + voice extras + webui deps -----------------------
# `pip install -e .[all,voice,edge-tts]` is idempotent — pip checks each
# dist's installed version against the requirement and skips if satisfied.
# Existing user state in ~/.hermes/ is never touched by pip.
info "Installing Hermes core (this may take a few minutes on first run) ..."
"$VENV_PY" -m pip install --upgrade pip >/dev/null
"$VENV_PY" -m pip install -e ".[all,voice,edge-tts]" || die "pip install failed"

info "Installing webui dependencies ..."
"$VENV_PY" -m pip install -r webui/requirements.txt || die "webui requirements install failed"

if [[ "$SKIP_PIPER" != "true" ]]; then
    info "Installing piper-tts (for JARVIS voice) ..."
    "$VENV_PY" -m pip install piper-tts || warn "piper-tts install failed — JARVIS personality will need a manual 'pip install piper-tts' later."
fi

# Touch the install marker so the launch script skips re-install on next launch.
mkdir -p "$VENV_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$VENV_DIR/.webui-installed"

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

# --- Next steps -------------------------------------------------------------
LAUNCH="$INSTALL_DIR/scripts/launch-webui.sh"
HERMES="$VENV_DIR/bin/hermes"

ok "JarvisCopilot installed at $INSTALL_DIR"
echo
echo "Your existing data in ~/.hermes/ (config, skills, cron jobs, sessions,"
echo "credentials, memory) was NOT touched by this install."
echo
echo "Next steps:"
echo
echo "  1) Authenticate with ChatGPT Codex (one-time, browser device-code flow):"
echo "     $HERMES auth add openai-codex --type oauth --no-browser"
echo
echo "  2) Pick the active model (one-time):"
echo "     $HERMES model openai-codex"
echo "       — or use any other provider; see '$HERMES model --help'"
echo
echo "  3) Launch the webui (binds 0.0.0.0:8787 with HTTPS):"
echo "     $LAUNCH"
echo
echo "  4) Open https://localhost:8787 in your browser. Brave/Chrome will warn"
echo "     about the self-signed cert — tap Advanced -> Proceed once and the"
echo "     mic/voice features will work."
echo
echo "Re-run this installer anytime to update code. Your config and data"
echo "stay put."
