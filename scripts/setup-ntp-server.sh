#!/usr/bin/env bash
set -euo pipefail

# ─── NTP Server setup (runs inside the Ubuntu VM) ────────────────────────────

# Disable systemd-timesyncd (conflicts with chrony)
systemctl disable --now systemd-timesyncd 2>/dev/null || true

# Install chrony if not present
if ! command -v chronyd &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq chrony
fi

# Configure chrony to serve time to the 192.168.121.0/24 subnet
cat > /etc/chrony/chrony.conf <<'EOF'
pool pool.ntp.org iburst
pool ntp.ubuntu.com iburst

# Allow VMs on the libvirt network to query this server
allow 192.168.121.0/24

# Serve time even if not synchronized to upstream
local stratum 10

# Log and drift
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
makestep 1.0 3
rtcsync
EOF

systemctl enable --now chrony
chronyc reload 2>/dev/null || true

# chrony sometimes fails to bind 0.0.0.0:123 on first start; restart to ensure it listens
sleep 2
if ! ss -tlnp 2>/dev/null | grep -q :123; then
  systemctl restart chrony
  sleep 1
fi

echo "NTP server ready on $(hostname -I | awk '{print $1}')"
