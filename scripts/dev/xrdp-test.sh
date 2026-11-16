#!/usr/bin/env bash
# Remote Desktop test target (plan 2026-11-15-remote-desktop, Task 4) — while the PC is still on
# Windows 11 Home (no RDP server), test the gateway and clients against xrdp in Docker:
#
#   scripts/dev/xrdp-test.sh          start: xrdp on 127.0.0.1:3390, guacd on 127.0.0.1:4822
#   scripts/dev/xrdp-test.sh stop     remove both containers and the network
#
# Both join the Docker network "jc-rdp", so guacd reaches the desktop as host "jc-xrdp", port 3389
# (that's the host a dev session must use through guacd). Desktop user/password: ubuntu / ubuntu.
# xrdp can't do NLA: run the webui (or a scratch tunnel) with JC_RDP_GUAC_SECURITY=any — never on
# the server, where the real PC requires NLA.
#
# Images are pinned by digest (repo dependency policy). guacd is amd64-only (emulated on Apple
# silicon: slower, fine for tests).
set -euo pipefail

XRDP_IMAGE="scottyhardy/docker-remote-desktop@sha256:78a58de9e24853a10e080e2789f93dc324234d5459220945eedf41680defafe9"
GUACD_IMAGE="guacamole/guacd@sha256:38232cae271361ef53db46faf5c49fe64049a1320a05b82c597425b69d6ce77e"   # 1.5.5
NET="jc-rdp"

stop() {
  docker rm -f jc-xrdp jc-guacd >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  echo "stopped"
}

if [[ "${1:-}" == "stop" ]]; then
  stop
  exit 0
fi

command -v docker >/dev/null || { echo "Docker isn't installed" >&2; exit 1; }
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f jc-xrdp jc-guacd >/dev/null 2>&1 || true
docker run -d --name jc-xrdp --network "$NET" --shm-size=1g -p 127.0.0.1:3390:3389 "$XRDP_IMAGE" >/dev/null
docker run -d --name jc-guacd --network "$NET" --platform linux/amd64 -p 127.0.0.1:4822:4822 "$GUACD_IMAGE" >/dev/null

# wait for both ports
for port in 3390 4822; do
  for _ in $(seq 1 60); do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  nc -z 127.0.0.1 "$port" >/dev/null 2>&1 || { echo "port $port didn't open" >&2; exit 1; }
done
cat <<EOF
xrdp   127.0.0.1:3390  (from guacd: jc-xrdp:3389)   user ubuntu / password ubuntu
guacd  127.0.0.1:4822
Run the gateway with JC_RDP_GUAC_SECURITY=any. Stop with: scripts/dev/xrdp-test.sh stop
EOF
