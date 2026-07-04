#!/usr/bin/env bash
set -euo pipefail

# ─── Prerequisites installer for Ubuntu 24.04 ───────────────────────────────
# Run this ONCE on the hypervisor host before `vagrant up`.
#
# Usage: sudo bash scripts/bootstrap.sh

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (sudo)."
  exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs)
info "Ubuntu version: $UBUNTU_VERSION"

# ── 1. System packages ─────────────────────────────────────────────────────
info "Installing system dependencies ..."
apt-get update -qq
apt-get install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  virt-manager virtinst bridge-utils cpu-checker \
  wget curl git jq

# ── 2. Verify KVM ──────────────────────────────────────────────────────────
if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
  info "KVM is available."
else
  err "KVM acceleration NOT available. Check VT-x/AMD-V in BIOS."
fi

# ── 3. Add current real user to libvirt groups ─────────────────────────────
SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
if id "$SUDO_USER" &>/dev/null; then
  usermod -aG libvirt "$SUDO_USER"
  usermod -aG kvm "$SUDO_USER"
  info "Added '$SUDO_USER' to libvirt / kvm groups (re-login required)."
fi

# ── 4. Start & enable libvirtd ─────────────────────────────────────────────
systemctl enable --now libvirtd

# ── 5. Install Vagrant ─────────────────────────────────────────────────────
if ! command -v vagrant &>/dev/null; then
  info "Installing Vagrant ..."
  wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor \
    > /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -qq
  apt-get install -y -qq vagrant
else
  info "Vagrant already installed: $(vagrant --version)"
fi

# ── 6. Install vagrant-libvirt plugin ──────────────────────────────────────
if ! vagrant plugin list | grep -q vagrant-libvirt; then
  info "Installing vagrant-libvirt plugin ..."
  vagrant plugin install vagrant-libvirt
else
  info "vagrant-libvirt plugin already installed."
fi

# ── 7. Install talosctl ────────────────────────────────────────────────────
if ! command -v talosctl &>/dev/null; then
  info "Installing talosctl ..."
  curl -sL https://talos.dev/install | sh
else
  info "talosctl already installed: $(talosctl version --client 2>/dev/null | head -1)"
fi

# ── 8. Install kubectl ─────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  info "Installing kubectl ..."
  K8S_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/amd64/kubectl"
  chmod +x kubectl
  mv kubectl /usr/local/bin/
else
  info "kubectl already installed: $(kubectl version --client --short 2>/dev/null | head -1)"
fi

# ── 9. Install helm ────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  info "Installing helm ..."
  curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  info "helm already installed: $(helm version --short 2>/dev/null | head -1)"
fi

# ── 10. Install cilium CLI ─────────────────────────────────────────────────
if ! command -v cilium &>/dev/null; then
  info "Installing cilium CLI ..."
  CILIUM_CLI_VERSION=$(curl -sL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  curl -sLO "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz"
  tar xzf cilium-linux-amd64.tar.gz -C /usr/local/bin/
  rm -f cilium-linux-amd64.tar.gz
else
  info "cilium CLI already installed: $(cilium version --client 2>/dev/null | head -1)"
fi

# ── 11. Download Talos ISO upfront ─────────────────────────────────────────
ISO_PATH="${ISO_PATH:-/tmp/metal-amd64.iso}"
if [ ! -f "$ISO_PATH" ]; then
  info "Downloading Talos ISO to $ISO_PATH ..."
  wget --progress=bar:force "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" -O "$ISO_PATH" || \
    curl -fL -o "$ISO_PATH" "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" || \
    warn "ISO download failed — will retry during 'vagrant up'"
fi

info "── Bootstrap complete ───────────────────────────────────────────────"
info "Log out and back in for group changes to take effect."
info "Then run: vagrant up --provider=libvirt"
