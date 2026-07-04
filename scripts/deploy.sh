#!/usr/bin/env bash
set -euo pipefail

# ─── Full Talos cluster deploy script ────────────────────────────────────────
# Prerequisite:  scripts/bootstrap.sh has been run (as root).
#                Vagrant VMs are up  (vagrant up --provider=libvirt).
#
# Usage:  ./scripts/deploy.sh [--cilium]

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${CYAN}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

# ─── Load env overrides ──────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-talos}"
CONTROL_COUNT="${CONTROL_COUNT:-3}"
WORKER_COUNT="${WORKER_COUNT:-1}"
ALLOW_SCHED_ON_CP="${ALLOW_SCHED_ON_CP:-false}"
SUBNET="${SUBNET:-192.168.121}"
VIP="${VIP:-${SUBNET}.100}"
INSTALL_DISK="${INSTALL_DISK:-/dev/vda}"
TALOS_VERSION="${TALOS_VERSION:-v1.9.5}"
ISO_PATH="${ISO_PATH:-/tmp/metal-amd64.iso}"
export TALOSCONFIG="${TALOSCONFIG:-$(pwd)/talosconfig}"

# Ensure ISO is downloaded
if [ ! -f "$ISO_PATH" ]; then
  info "Downloading Talos ISO to $ISO_PATH ..."
  wget --progress=bar:force "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" -O "$ISO_PATH" || \
    curl -fL -o "$ISO_PATH" "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" || {
      err "Failed to download Talos ISO"
      exit 1
    }
fi

# ─── 1. Get VM IPs from virsh ──────────────────────────────────────────────
info "Discovering VM IPs ..."
get_vm_ips() {
  local pattern="$1"
  virsh list --name 2>/dev/null | grep -i "$pattern" | while read -r name; do
    virsh domifaddr "$name" 2>/dev/null \
      | grep ipv4 | awk '{print $4}' | cut -d/ -f1
  done | sort -u
}

CP_IPS=()
mapfile -t CP_IPS < <(get_vm_ips "${CLUSTER_NAME}-control-plane")
WORKER_IPS=()
mapfile -t WORKER_IPS < <(get_vm_ips "${CLUSTER_NAME}-worker")

if [[ ${#CP_IPS[@]} -eq 0 ]]; then
  err "No control-plane VMs found. Run: vagrant up --provider=libvirt"
  exit 1
fi

info "Control-plane IPs: ${CP_IPS[*]}"
info "Worker IPs:        ${WORKER_IPS[*]:-(none)}"
FIRST_CP="${CP_IPS[0]}"

# ─── Helper: wait for Talos maintenance mode on a node ─────────────────────
wait_for_maintenance() {
  local ip=$1
  local max=30
  info "Waiting for node $ip to reach maintenance mode ..."
  for i in $(seq 1 $max); do
    if talosctl -n "$ip" version --insecure --short 2>/dev/null \
       | grep -q Talos; then
      info "Node $ip ready in maintenance mode."
      return 0
    fi
    sleep 10
  done
  err "Node $ip did NOT reach maintenance mode in ${max}x10s."
  exit 1
}

# ─── 2. Generate cluster config ────────────────────────────────────────────
info "Generating Talos configuration ..."
rm -f talosconfig controlplane.yaml worker.yaml

talosctl gen config "$CLUSTER_NAME" "https://${VIP}:6443" \
  --install-disk "$INSTALL_DISK" \
  --config-patch @config/cluster-patch.yaml

# Set talosconfig endpoints
talosctl config endpoint "${CP_IPS[@]}"

# ─── 3. Apply configs to control-plane nodes ───────────────────────────────
for i in "${!CP_IPS[@]}"; do
  ip="${CP_IPS[$i]}"
  idx=$((i + 1))

  wait_for_maintenance "$ip"

  # Create per-node patch with hostname + VIP
  cat > "/tmp/${CLUSTER_NAME}-cp-${idx}-patch.yaml" <<EOF
machine:
  network:
    hostname: ${CLUSTER_NAME}-control-plane-${idx}
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip:
          ip: ${VIP}
cluster:
  allowSchedulingOnControlPlanes: ${ALLOW_SCHED_ON_CP}
  apiServer:
    certSANs:
      - ${VIP}
EOF

  info "Applying config to control-plane node $idx ($ip) ..."
  talosctl -n "$ip" apply-config --insecure \
    --file controlplane.yaml \
    --config-patch @"/tmp/${CLUSTER_NAME}-cp-${idx}-patch.yaml"
done

# ─── 4. Bootstrap etcd on first control plane ─────────────────────────────
info "Waiting for etcd to be ready on $FIRST_CP (up to 5 min) ..."
sleep 60

talosctl -n "$FIRST_CP" bootstrap
info "Bootstrap initiated on $FIRST_CP."

# Wait for bootstrap to complete
info "Waiting for cluster to become healthy ..."
talosctl -n "$FIRST_CP" health --wait-timeout=10m || warn "Health check took long; continuing ..."

# ─── 5. Retrieve kubeconfig ────────────────────────────────────────────────
info "Retrieving kubeconfig ..."
talosctl -n "$FIRST_CP" kubeconfig ./kubeconfig
export KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig}"

# ─── 6. Apply configs to worker nodes ──────────────────────────────────────
for i in "${!WORKER_IPS[@]}"; do
  ip="${WORKER_IPS[$i]}"
  idx=$((i + 1))

  wait_for_maintenance "$ip"

  cat > "/tmp/${CLUSTER_NAME}-worker-${idx}-patch.yaml" <<EOF
machine:
  network:
    hostname: ${CLUSTER_NAME}-worker-${idx}
EOF

  info "Applying config to worker node $idx ($ip) ..."
  talosctl -n "$ip" apply-config --insecure \
    --file worker.yaml \
    --config-patch @"/tmp/${CLUSTER_NAME}-worker-${idx}-patch.yaml"
done

# ─── 7. Wait for all nodes to be Ready ─────────────────────────────────────
info "Waiting for all nodes to be Ready ..."
for i in $(seq 1 30); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '{print $2}' | grep -c "^Ready" || true)
  total=$((CONTROL_COUNT + WORKER_COUNT))
  if [[ "$ready" -ge "$total" ]]; then
    info "All $total nodes are Ready!"
    break
  fi
  sleep 10
done

kubectl get nodes -o wide

# ─── 8. (Optional) Install Cilium ──────────────────────────────────────────
if [[ "${1:-}" == "--cilium" ]]; then
  info "Installing Cilium CNI ..."

  # Gateway API CRDs
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml

  helm repo add cilium https://helm.cilium.io/
  helm repo update

  cilium install \
    --helm-set=ipam.mode=kubernetes \
    --helm-set=kubeProxyReplacement=true \
    --helm-set=securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --helm-set=securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --helm-set=cgroup.autoMount.enabled=false \
    --helm-set=cgroup.hostRoot=/sys/fs/cgroup \
    --helm-set=l2announcements.enabled=true \
    --helm-set=externalIPs.enabled=true \
    --set gatewayAPI.enabled=true \
    --helm-set=devices=e+ \
    --helm-set=operator.replicas=1

  cilium status --wait

  # Apply L2 announcement policy + IP pool
  kubectl apply -f manifests/

  info "Cilium installed. Verify with: cilium status"
fi

# ─── 9. Summary ────────────────────────────────────────────────────────────
info "── Cluster ready ────────────────────────────────────────────────────"
info "Cluster name : $CLUSTER_NAME"
info "API VIP      : https://${VIP}:6443"
info "Nodes        :"
kubectl get nodes -o wide | awk '{print "  "$0}'
info ""
info "kubeconfig   : $(pwd)/kubeconfig"
info "talosconfig  : $TALOSCONFIG"
info ""
info "Quick cmds:"
info "  export KUBECONFIG=$(pwd)/kubeconfig"
info "  kubectl get nodes"
info "  talosctl -n ${FIRST_CP} health"
