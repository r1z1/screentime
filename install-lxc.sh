#!/usr/bin/env bash
# Create a Debian 12 LXC on a Proxmox host and run screentime-server in it.
# Run as root ON THE PROXMOX HOST:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/OWNER/screentime/main/packaging/proxmox/install-lxc.sh)"
# That downloads the screentime-server binary from the latest release of
# github.com/$REPO (set REPO=owner/name). Or install a binary you built
# (glibc <= 2.36, Debian 12):
#   ./install-lxc.sh /path/to/screentime-server
# Options (env): CTID, CT_HOSTNAME, STORAGE (rootfs, default local-lvm),
#   TEMPLATE_STORAGE (default local), BRIDGE (default vmbr0), MEMORY (MB, 256),
#   DISK (GB, 2), IP (default dhcp, or e.g. 192.168.1.50/24 with GW=192.168.1.1)
# Re-run with an existing CTID to update the binary only.
set -euo pipefail

REPO=${REPO:-OWNER/screentime}
RELEASE=https://github.com/$REPO/releases/latest/download
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [ -n "${1:-}" ]; then
    BIN=$1
    [ -x "$BIN" ] || { echo "$BIN is not an executable file" >&2; exit 1; }
else
    BIN=$WORK/screentime-server
    curl -fsSL "$RELEASE/screentime-server" -o "$BIN" || { echo "cannot download $RELEASE/screentime-server (set REPO=owner/name)" >&2; exit 1; }
    chmod 0755 "$BIN"
fi
UNIT=$WORK/screentime-server.service
cat > "$UNIT" <<'UNITEOF'
[Unit]
Description=screentime parent server
After=network-online.target
Wants=network-online.target

[Service]
User=screentime
StateDirectory=screentime
EnvironmentFile=-/etc/screentime/server.env
Environment=SCREENTIME_DB=sqlite:///var/lib/screentime/server.db?mode=rwc
Environment=SCREENTIME_LISTEN=0.0.0.0:8787
ExecStart=/usr/local/bin/screentime-server
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNITEOF
command -v pct >/dev/null || { echo "pct not found: run this on the Proxmox host" >&2; exit 1; }

CTID=${CTID:-$(pvesh get /cluster/nextid)}
CT_HOSTNAME=${CT_HOSTNAME:-screentime}
STORAGE=${STORAGE:-local-lvm}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
BRIDGE=${BRIDGE:-vmbr0}
NET="name=eth0,bridge=$BRIDGE,ip=${IP:-dhcp}${GW:+,gw=$GW}"

if ! pct status "$CTID" >/dev/null 2>&1; then
    pveam update >/dev/null
    TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort | tail -1)
    [ -n "$TEMPLATE" ] || { echo "no debian-12 template found" >&2; exit 1; }
    pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
        --hostname "$CT_HOSTNAME" --unprivileged 1 --onboot 1 \
        --memory "${MEMORY:-256}" --cores 1 --rootfs "$STORAGE:${DISK:-2}" \
        --net0 "$NET" --features nesting=0
    pct start "$CTID"
    for _ in $(seq 30); do pct exec "$CTID" -- true 2>/dev/null && break; sleep 1; done
fi

pct push "$CTID" "$BIN" /usr/local/bin/screentime-server --perms 0755
pct push "$CTID" "$UNIT" /etc/systemd/system/screentime-server.service
pct exec "$CTID" -- bash -c '
    id screentime >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin screentime
    install -d -m 0750 -o root -g screentime /etc/screentime
    [ -e /etc/screentime/server.env ] || cat > /etc/screentime/server.env <<ENV
# SCREENTIME_NTFY_URL=http://ntfy.lan:8080
# SCREENTIME_NTFY_TOKEN=tk_...
# SCREENTIME_PUBLIC_URL=https://screentime.example.com
ENV
    systemctl daemon-reload
    systemctl enable screentime-server
    systemctl restart screentime-server
'

sleep 2
IPADDR=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo
echo "screentime-server is running in container $CTID"
echo "  open:   http://$IPADDR:8787   (create the parent account on first visit)"
echo "  config: pct exec $CTID -- nano /etc/screentime/server.env, then systemctl restart screentime-server"
echo "  data:   /var/lib/screentime/server.db inside the container (back it up)"
echo "Use http://$IPADDR:8787 as the server URL when pairing child machines."
