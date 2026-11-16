# guacd on the server (Remote Desktop web gateway)

The web Remote Desktop client (`webui/static/rdp.js`) talks to the webui's Guacamole tunnel
(`webui/api/rdp_guac.py`, `wss://…/api/rdp/guac/<session>`), which connects to **guacd on
127.0.0.1:4822** and from there to the PC's RDP port over Tailscale. guacd must never listen on a
public interface.

Not installed yet — install it when the PC is on Windows 11 Pro (plan Task 10).

## Install (Debian 13, jc-hermes) — native build

Debian 13 no longer packages guacd, and jc-hermes is an LXC container (no Docker), so build it:
`sudo deploy/guacd/build-guacd.sh` (Guacamole 1.6.0 — the first with FreeRDP 3 —, checksum-verified,
RDP only, systemd unit `guacd` as user `guacd` on 127.0.0.1:4822, transfer folders in
`/var/lib/jarvis-rdp/drive`). Then add `Environment=JC_RDP_DRIVE_ROOT=/var/lib/jarvis-rdp/drive` to the
webui unit (drop-in) and restart it. The apt steps below are kept for other hosts.

## Install (Debian 12 and older, where the package exists)

```bash
sudo apt update
apt-cache policy guacd libguac-client-rdp0      # want 1.5.x; see "Version" below
sudo apt install -y guacd libguac-client-rdp0
```

Bind to loopback only — `/etc/guacamole/guacd.conf`:

```ini
[server]
bind_host = 127.0.0.1
bind_port = 4822
```

```bash
sudo systemctl enable --now guacd
sudo systemctl restart guacd        # after editing guacd.conf
ss -ltnp | grep 4822                # must show 127.0.0.1:4822 only
```

The webui runs as its own user and writes the per-session drive folders under
`$HERMES_HOME/rdp/drive/<session>`; guacd opens that path for RDP drive redirection, so the guacd
user needs read/write there:

```bash
sudo mkdir -p ~jarvis/.jarviscopilot/rdp/drive          # the webui's HERMES_HOME
sudo setfacl -R -m u:guacd:rwx -m d:u:guacd:rwx ~jarvis/.jarviscopilot/rdp/drive
```

(Adjust the path/user to the server's actual HERMES_HOME and webui user.)

## Check

```bash
nc -z 127.0.0.1 4822 && echo guacd up
nc -z 100.119.223.124 3389 && echo PC reachable over Tailscale   # after the PC's RDP setup
```

Then open Remote Desktop from the web Agents card: Face ID on the iPhone, then the PC's desktop.

## Version

The tunnel speaks the Guacamole 1.5 protocol (guacamole-common-js 1.5.5 in the browser). If
Debian's `guacd` is older than 1.5 or misses the RDP plugin, run the same pinned image the dev
target uses, bound to loopback:

```bash
docker run -d --name guacd --restart unless-stopped -p 127.0.0.1:4822:4822 \
  -v ~jarvis/.jarviscopilot/rdp/drive:/home/jarvis/.jarviscopilot/rdp/drive \
  guacamole/guacd@sha256:38232cae271361ef53db46faf5c49fe64049a1320a05b82c597425b69d6ce77e   # 1.5.5
```

(mount the drive folder at the same path the webui passes as `drive-path`).

## Never

- Don't set `JC_RDP_GUAC_SECURITY` on the server (dev-only override for the xrdp test container;
  the real PC requires NLA).
- Don't open 4822 in any firewall.

## Local testing

`scripts/dev/xrdp-test.sh` starts xrdp (127.0.0.1:3390) and guacd (127.0.0.1:4822) in Docker.
