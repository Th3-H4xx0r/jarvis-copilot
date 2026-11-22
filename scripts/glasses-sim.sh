#!/usr/bin/env bash
# Run simulated Ray-Ban Meta glasses against Jarvis on this Mac — no glasses needed.
#
#   scripts/glasses-sim.sh                         # asks "What is seven times eight?"
#   scripts/glasses-sim.sh --prompt "What's the capital of France?" --prompt "And Spain?"
#   scripts/glasses-sim.sh --no-speak --port 8795
#
# What happens:
#   1. Builds cipher982/ray-ban-meta-custom-agents (MIT) at a pinned commit, once, into a cache dir.
#      Its `glasses-cli simulate` plays software glasses that speak the real Bluetooth protocol
#      (handshake, trust, link setup) in memory, and voices the wearer with macOS `say`.
#   2. Starts Jarvis's glasses relay (`python -m glasses_relay`): speech-to-text -> your configured
#      Jarvis model -> text-to-speech, streamed back to the glasses.
#   3. Runs your prompts, then prints what the wearer said, what Jarvis answered and how fast, and
#      speaks each answer out loud (skip with --no-speak). Exit status is the simulator's.
#
# Nothing here touches the Meta app, a Meta account or real glasses.
set -euo pipefail

SIM_REPO="https://github.com/cipher982/ray-ban-meta-custom-agents.git"
SIM_SHA="584031e0c8f5aba8b14949ce6e8b1a70c33285a1"   # pinned (dependency policy: git deps by SHA)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jarvis-glasses-sim"
SIM_DIR="$CACHE_DIR/ray-ban-meta-custom-agents"
DEFAULT_PORT=8791          # the relay's default; 8787 is usually taken by a running Jarvis

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

prompts=()
port="$DEFAULT_PORT"
speak=1
rebuild=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) [[ $# -ge 2 ]] || { echo "--prompt needs a value" >&2; exit 2; }; prompts+=("$2"); shift 2 ;;
    --port) [[ $# -ge 2 ]] || { echo "--port needs a value" >&2; exit 2; }; port="$2"; shift 2 ;;
    --no-speak) speak=0; shift ;;
    --rebuild) rebuild=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ ${#prompts[@]} -gt 0 ]] || prompts=("What is seven times eight?")
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a number" >&2; exit 2; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "This simulator needs macOS (it voices the wearer with 'say')." >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift not found — install Xcode or the Command Line Tools." >&2; exit 1; }
command -v git >/dev/null || { echo "git not found." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Same venv probe order as scripts/run_tests.sh.
PY=""
for candidate in "$REPO_ROOT/.venv" "$REPO_ROOT/venv" "$HOME/.jarviscopilot/jarviscopilot/venv"; do
  if [[ -x "$candidate/bin/python" ]]; then PY="$candidate/bin/python"; break; fi
done
[[ -n "$PY" ]] || { echo "No Python venv found (.venv, venv, or ~/.jarviscopilot/jarviscopilot/venv)." >&2; exit 1; }
"$PY" -c "import websockets" 2>/dev/null || { echo "The venv at $PY lacks 'websockets' — install the repo's dependencies first." >&2; exit 1; }

# --- 1. The simulator, built once at the pinned commit -------------------------------------
mkdir -p "$CACHE_DIR"
if [[ ! -d "$SIM_DIR/.git" ]]; then
  echo "▶ Fetching the glasses simulator (cipher982/ray-ban-meta-custom-agents, MIT)…"
  git clone --quiet "$SIM_REPO" "$SIM_DIR"
fi
if [[ "$(git -C "$SIM_DIR" rev-parse HEAD 2>/dev/null)" != "$SIM_SHA" ]]; then
  git -C "$SIM_DIR" cat-file -e "$SIM_SHA^{commit}" 2>/dev/null || git -C "$SIM_DIR" fetch --quiet origin
  git -C "$SIM_DIR" checkout --quiet --detach "$SIM_SHA"
fi
MARKER="$CACHE_DIR/.built-sha"
BIN_DIR="$(cd "$SIM_DIR" && swift build --product glasses-cli --show-bin-path 2>/dev/null || true)"
CLI="$BIN_DIR/glasses-cli"
if [[ $rebuild -eq 1 || ! -x "$CLI" || "$(cat "$MARKER" 2>/dev/null)" != "$SIM_SHA" ]]; then
  echo "▶ Building glasses-cli (first time takes a minute)…"
  (cd "$SIM_DIR" && swift build --product glasses-cli)
  BIN_DIR="$(cd "$SIM_DIR" && swift build --product glasses-cli --show-bin-path)"
  CLI="$BIN_DIR/glasses-cli"
  echo "$SIM_SHA" > "$MARKER"
fi

# --- 2. Jarvis's glasses relay on a free port ----------------------------------------------
# The relay answers with your configured Jarvis model (auxiliary.voice lane, else auto). Many Macs
# have none — Jarvis itself runs on the server — so say so and use local Claude Code if present.
if [[ -z "${JARVIS_RELAY_PROVIDER:-}" ]]; then
  if ! "$PY" - 2>/dev/null <<'PY'
import sys
from glasses_relay.config import RelayConfig
if RelayConfig.from_sources().brain_provider:
    sys.exit(0)
try:
    from agent.auxiliary_client import _resolve_auto
    client, _model = _resolve_auto()
except Exception:
    sys.exit(0)  # can't tell — let the relay try and report
sys.exit(0 if client is not None else 1)
PY
  then
    if command -v claude >/dev/null; then
      export JARVIS_RELAY_PROVIDER=claude-code
      export JARVIS_RELAY_MODEL="${JARVIS_RELAY_MODEL:-haiku}"
      echo "▶ No Jarvis model is set up on this Mac — answering with your local Claude Code ($JARVIS_RELAY_MODEL)."
      echo "  (Set JARVIS_RELAY_PROVIDER / JARVIS_RELAY_MODEL to use another model.)"
    else
      echo "✗ No Jarvis model is set up on this Mac and Claude Code isn't installed." >&2
      echo "  Set JARVIS_RELAY_PROVIDER and JARVIS_RELAY_MODEL (or configure auxiliary.voice), then rerun." >&2
      exit 1
    fi
  fi
fi

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
start_port="$port"
while port_busy "$port"; do
  port=$((port + 1))
  [[ $port -lt $((start_port + 50)) ]] || { echo "No free port near $start_port." >&2; exit 1; }
done
[[ "$port" == "$start_port" ]] || echo "▶ Port $start_port is busy — using $port."

RELAY_LOG="$(mktemp -t glasses-relay.XXXXXX)"
relay_pid=""
cleanup() {
  if [[ -n "$relay_pid" ]] && kill -0 "$relay_pid" 2>/dev/null; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "▶ Starting Jarvis's glasses relay on port $port (warming speech recognition)…"
"$PY" -m glasses_relay "$port" >"$RELAY_LOG" 2>&1 &
relay_pid=$!
ready=0
for _ in $(seq 1 240); do                     # up to 120 s: a first run may download the STT model
  if ! kill -0 "$relay_pid" 2>/dev/null; then break; fi
  if port_busy "$port"; then ready=1; break; fi
  sleep 0.5
done
if [[ $ready -ne 1 ]]; then
  echo "✗ The relay didn't come up. Its log ($RELAY_LOG):" >&2
  tail -n 30 "$RELAY_LOG" >&2
  exit 1
fi

# --- 3. Run the simulated glasses -----------------------------------------------------------
echo "▶ Running the simulated glasses…"
echo
sim_args=(simulate --server "http://127.0.0.1:$port")
for p in "${prompts[@]}"; do sim_args+=(--prompt "$p"); done
set +e
"$CLI" "${sim_args[@]}"
status=$?
set -e

echo
echo "──────── What happened ────────"
ANSWERS_FILE="$(mktemp -t glasses-answers.XXXXXX)"
if "$PY" - "$RELAY_LOG" "$ANSWERS_FILE" <<'PY'
import json, re, sys
pattern = re.compile(r'turn (r\d+) heard=(".*?") said=(".*") first_audio_ms=(\d+)$')
failed = re.compile(r"turn (r\d+) failed: (.*)$")
turns = []
with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    for line in log:
        line = line.rstrip("\n")
        m = pattern.search(line)
        if m:
            turns.append((json.loads(m.group(2)), json.loads(m.group(3)), int(m.group(4)), None))
            continue
        f = failed.search(line)
        if f:
            turns.append(("", "", 0, f.group(2)))
errors = 0
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for heard, said, ms, error in turns:
        if error:
            errors += 1
            print("  Jarvis: couldn't answer — %s" % error)
            continue
        if not heard:
            print("  You:    (Jarvis heard nothing)")
            continue
        print("  You:    %s" % heard)
        print("  Jarvis: %s   (first audio %.1f s after you stopped)" % (said, ms / 1000.0))
        out.write(said.replace("\n", " ") + "\n")
if not turns:
    print("  (no turns reached Jarvis — see the relay log)")
sys.exit(1 if errors or not turns else 0)
PY
then answers_ok=1; else answers_ok=0; fi
if [[ $status -eq 0 && $answers_ok -eq 1 ]]; then
  echo "  Result: PASS"
else
  [[ $status -ne 0 ]] || status=1          # the glasses protocol passed, but Jarvis didn't answer
  echo "  Result: FAIL — relay log: $RELAY_LOG"
fi

if [[ $speak -eq 1 ]]; then
  while IFS= read -r answer; do
    [[ -n "$answer" ]] && say -- "$answer"
  done < "$ANSWERS_FILE"
fi
rm -f "$ANSWERS_FILE"
[[ $status -ne 0 ]] || rm -f "$RELAY_LOG"
exit "$status"
