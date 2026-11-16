#!/usr/bin/env bash
# Builds and installs guacd natively on jc-hermes (Debian 13, an LXC container — no Docker): Debian 13
# no longer packages guacd, and Guacamole 1.6.0 is the first release that builds against the FreeRDP 3
# Debian ships. RDP only (no VNC/SSH/telnet), installed under /usr/local, run by systemd as user
# `guacd`, bound to 127.0.0.1:4822. Idempotent; run as root.
set -euo pipefail
VERSION=1.6.0
URL="https://archive.apache.org/dist/guacamole/${VERSION}/source/guacamole-server-${VERSION}.tar.gz"
SHA256_URL="${URL}.sha256"
DRIVE=/var/lib/jarvis-rdp/drive
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

apt-get install -y --no-install-recommends build-essential autoconf automake libtool-bin pkg-config \
  libcairo2-dev libjpeg62-turbo-dev libpng-dev libwebp-dev uuid-dev libssl-dev freerdp3-dev libpango1.0-dev

cd "$work"
curl -fsSLo src.tar.gz "$URL"
expected=$(curl -fsSL "$SHA256_URL" | awk '{print $1}')
echo "$expected  src.tar.gz" | sha256sum -c -
tar xzf src.tar.gz
cd "guacamole-server-${VERSION}"
./configure --prefix=/usr/local --with-freerdp --without-vnc --without-ssh --without-telnet \
  --without-kubernetes --without-pulse --disable-guacenc --disable-guaclog --with-systemd-dir=no
make -j"$(nproc)"
make install
ldconfig

id guacd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/guacd --create-home --shell /usr/sbin/nologin guacd
install -d -m 2770 -o guacd -g guacd "$DRIVE"   # setgid: session folders the webui (root) makes stay group guacd
mkdir -p /etc/guacamole
cat > /etc/guacamole/guacd.conf <<'CONF'
[server]
bind_host = 127.0.0.1
bind_port = 4822
CONF
cat > /etc/systemd/system/guacd.service <<'UNIT'
[Unit]
Description=Guacamole proxy (Jarvis Remote Desktop web gateway, loopback only)
After=network-online.target tailscaled.service

[Service]
User=guacd
Group=guacd
ExecStart=/usr/local/sbin/guacd -f -b 127.0.0.1 -l 4822
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/jarvis-rdp /var/lib/guacd
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now guacd
systemctl restart guacd
sleep 1
ss -ltnp | grep 4822
