#!/usr/bin/env bash
set -euo pipefail

# ─── Longhorn distributed storage installer ─────────────────────────────────
# Prerequisites:
#   - Talos cluster deployed with deploy.sh (kernel modules + system extensions
#     are baked into the machine config for new deploys)
#   - kubectl connected to the cluster

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig}"
export KUBECONFIG

if ! kubectl get nodes &>/dev/null; then
  err "Cannot connect to cluster. Is KUBECONFIG set?"
  exit 1
fi

info "Adding Longhorn Helm repo ..."
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || helm repo update longhorn
helm repo update 2>/dev/null || true

info "Creating longhorn-system namespace with PodSecurity label ..."
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
EOF

info "Installing Longhorn ..."
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath=/var/mnt/longhorn

info "Waiting for Longhorn to be ready ..."
kubectl rollout status -n longhorn-system deployment/longhorn-driver-deployer --timeout=5m
kubectl rollout status -n longhorn-system daemonset/longhorn-manager --timeout=5m

info "Longhorn installed."
info "Default StorageClass should be available:"
kubectl get sc -o wide 2>/dev/null | head -5
