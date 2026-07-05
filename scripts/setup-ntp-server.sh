#!/usr/bin/env bash
set -euo pipefail

# ─── NTP Server setup on the libvirt host ────────────────────────────────────
# Runs as part of bootstrap.sh. The host at 192.168.121.1 serves NTP to VMs.

info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m $*"; }

# Install chrony if not present
if ! command -v chronyd &>/dev/null; then
  info "Installing chrony ..."
  apt-get update -qq
  apt-get install -y -qq chrony
fi

# Configure chrony to serve time to the libvirt VMs
if ! grep -q '^allow 192.168.121.0/24' /etc/chrony/chrony.conf; then
  echo "allow 192.168.121.0/24" >> /etc/chrony/chrony.conf
fi
if ! grep -q '^local stratum' /etc/chrony/chrony.conf; then
  echo "local stratum 10" >> /etc/chrony/chrony.conf
fi

systemctl enable --now chrony
chronyc reload 2>/dev/null || systemctl restart chrony

# Verify chrony is listening on port 123
sleep 1
if ss -uln 2>/dev/null | grep -q :123; then
  info "chrony NTP server ready on 192.168.121.1:123"
else
  systemctl restart chrony
  sleep 1
  if ss -uln 2>/dev/null | grep -q :123; then
    info "chrony NTP server ready after restart"
  else
    warn "chrony failed to bind port 123"
  fi
fi
