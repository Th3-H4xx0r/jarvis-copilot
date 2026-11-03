#!/usr/bin/env bash
# Install and configure coturn (TURN/STUN) for Mac screen sharing.
#
# Run as root on the Jarvis server, from the repo checkout:
#   sudo scripts/setup_coturn.sh                 # detect the public IP
#   sudo scripts/setup_coturn.sh --ip 203.0.113.7 [--realm jarvis] [--min-port 49160] [--max-port 49200]
#
# Idempotent: re-running rewrites the same config and restarts coturn.
#
# The TURN password scheme is coturn's REST one (`use-auth-secret`): the web UI
# (webui/api/screen_share.py) hands viewers and the Mac a user "<expiry>:jarvis"
# and base64(HMAC-SHA1(secret, user)). The secret is `screen.turn_secret` in
# $HERMES_HOME/config.yaml — this script creates it when missing (the web UI
# would too, on first use) and writes `screen.turn_host` / `screen.turn_port` so
# the web UI starts offering the TURN server (it reads the screen section on every
# request, so no web UI restart is needed).
#
# Firewall: open 3478/udp, 3478/tcp and the relay range (default 49160-49200/udp)
# in the cloud provider's firewall / security group as well. The script opens
# them in ufw when ufw is active.
set -euo pipefail

IP=""
REALM="jarvis"
PORT=3478
MIN_PORT=49160
MAX_PORT=49200
while [ $# -gt 0 ]; do
  case "$1" in
    --ip) IP="$2"; shift 2 ;;
    --realm) REALM="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --min-port) MIN_PORT="$2"; shift 2 ;;
    --max-port) MAX_PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.jarviscopilot}"
CONFIG="${HERMES_CONFIG_PATH:-$HERMES_HOME/config.yaml}"
PY="$REPO/.venv/bin/python"
[ -x "$PY" ] || PY="$REPO/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

# 1. The public IP viewers and the Mac will reach (Cloudflare can't proxy TURN).
if [ -z "$IP" ]; then
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    IP="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    IP=""
  done
fi
[ -n "$IP" ] || { echo "could not detect the public IP; pass --ip" >&2; exit 1; }
# The address coturn binds: when the public IP isn't on an interface (cloud 1:1 NAT),
# coturn needs "external-ip=<public>/<private>".
PRIVATE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [ -n "$PRIVATE_IP" ] && [ "$PRIVATE_IP" != "$IP" ]; then
  EXTERNAL="$IP/$PRIVATE_IP"
else
  EXTERNAL="$IP"
fi
echo "public IP: $IP (external-ip=$EXTERNAL)"

# 2. The shared secret in config.yaml (made once) + where the TURN server is.
SECRET="$("$PY" - "$CONFIG" "$IP" "$PORT" <<'PYEOF'
import os, secrets, sys, yaml
path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
sec = data.get("screen") if isinstance(data.get("screen"), dict) else {}
secret = str(sec.get("turn_secret") or "").strip() or secrets.token_hex(32)
changed = (sec.get("turn_secret") != secret or sec.get("turn_host") != host or sec.get("turn_port") != port)
sec.update({"turn_secret": secret, "turn_host": host, "turn_port": port})
data["screen"] = sec
if changed:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".coturn-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, sort_keys=False, allow_unicode=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
print(secret)
PYEOF
)"
[ -n "$SECRET" ] || { echo "could not read or create screen.turn_secret" >&2; exit 1; }

# 3. coturn itself.
if ! command -v turnserver >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq coturn
fi
[ -f /etc/default/coturn ] && sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn

CONF=/etc/turnserver.conf
umask 077
cat > "$CONF.new" <<EOF
# Written by JarvisCopilot scripts/setup_coturn.sh — re-run it instead of editing.
listening-port=$PORT
external-ip=$EXTERNAL
realm=$REALM
server-name=$REALM
use-auth-secret
static-auth-secret=$SECRET
fingerprint
min-port=$MIN_PORT
max-port=$MAX_PORT
# TLS (5349) is not used: WebRTC already encrypts the media end to end.
no-tls
no-dtls
no-cli
no-multicast-peers
# Never relay into private ranges (the server's own network, loopback).
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=::1
total-quota=50
user-quota=12
stale-nonce=600
log-file=syslog
simple-log
EOF
chown root:turnserver "$CONF.new" 2>/dev/null || true
chmod 640 "$CONF.new"
mv "$CONF.new" "$CONF"

# 4. Firewall (ufw when it is active; the cloud firewall is on you).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/udp" >/dev/null
  ufw allow "$PORT/tcp" >/dev/null
  ufw allow "$MIN_PORT:$MAX_PORT/udp" >/dev/null
  echo "ufw: opened $PORT/udp, $PORT/tcp, $MIN_PORT-$MAX_PORT/udp"
fi

# 5. Run it.
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn
sleep 1
if systemctl is-active --quiet coturn; then
  echo "coturn running on $IP:$PORT (relay $MIN_PORT-$MAX_PORT/udp), realm $REALM"
else
  echo "coturn failed to start — journalctl -u coturn -n 50" >&2
  exit 1
fi
echo "config: screen.turn_host=$IP screen.turn_port=$PORT in $CONFIG"
echo "Open in the cloud firewall: $PORT/udp, $PORT/tcp, $MIN_PORT-$MAX_PORT/udp"
