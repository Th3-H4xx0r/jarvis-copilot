#!/usr/bin/env bash
# Authorise Google Drive on this Mac and hand the token to Jarvis as a dashcam upload destination.
#
#   connect_drive.sh                          # print the destination JSON to paste into the app
#   connect_drive.sh --ssh jc-hermes          # add it on the Jarvis server over ssh
#   connect_drive.sh --post                   # add it to the web UI running on this machine
#   options: --name "Google Drive"  --path dashcam  --client-id ID --client-secret SECRET
#            --remote-script PATH (with --ssh; default: JarvisCopilot/skills/... under the remote home)
#
# `rclone authorize drive` opens a browser to sign in; the server never needs a browser. The
# token travels on stdin or in the printed JSON, never as a command argument (the client secret
# reaches rclone authorize as one, on this Mac only, and dashcam.py through the environment).
# Bring your own client id/secret: rclone's shared Drive client id is being retired during 2026.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHCAM="$HERE/dashcam.py"
NAME="Google Drive"
FOLDER="dashcam"
MODE="print"
SSH_HOST=""
REMOTE_SCRIPT="JarvisCopilot/skills/smart-home/jarvis-dashcam/scripts/dashcam.py"
CLIENT_ID=""
CLIENT_SECRET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --path) FOLDER="$2"; shift 2 ;;
    --post) MODE="post"; shift ;;
    --ssh) MODE="ssh"; SSH_HOST="$2"; shift 2 ;;
    --remote-script) REMOTE_SCRIPT="$2"; shift 2 ;;
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "connect_drive.sh: unknown option $1" >&2; exit 1 ;;
  esac
done

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone is not installed: brew install rclone" >&2
  exit 1
fi
if [ -n "$CLIENT_ID" ] && [ -z "$CLIENT_SECRET" ]; then
  echo "--client-id needs --client-secret too" >&2
  exit 1
fi

echo "Opening a browser to sign in to Google Drive..." >&2
if [ -n "$CLIENT_ID" ]; then
  AUTH_OUT="$(rclone authorize drive "$CLIENT_ID" "$CLIENT_SECRET")"
else
  AUTH_OUT="$(rclone authorize drive)"
fi

PAYLOAD_ARGS=(--name "$NAME" --path "$FOLDER")
if [ -n "$CLIENT_ID" ]; then
  PAYLOAD_ARGS+=(--client-id "$CLIENT_ID")
fi
PAYLOAD="$(printf '%s' "$AUTH_OUT" | DASHCAM_DRIVE_CLIENT_SECRET="$CLIENT_SECRET" \
  python3 "$DASHCAM" drive-payload "${PAYLOAD_ARGS[@]}")"

case "$MODE" in
  print)
    echo "Paste this into the Jarvis app (Dashcam > Destinations > Add > Google Drive). It holds a" >&2
    echo "login token: don't share it." >&2
    printf '%s\n' "$PAYLOAD"
    ;;
  post)
    printf '%s' "$PAYLOAD" | python3 "$DASHCAM" add-destination --json-stdin
    ;;
  ssh)
    printf '%s' "$PAYLOAD" | ssh "$SSH_HOST" "python3 $(printf '%q' "$REMOTE_SCRIPT") add-destination --json-stdin"
    ;;
esac
