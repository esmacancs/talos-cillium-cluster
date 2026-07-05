#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${CYAN}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig}"
export KUBECONFIG

# ─── 1. Validate prerequisites ─────────────────────────────────────────────
if ! command -v flux &>/dev/null; then
  err "flux CLI not found. Run 'sudo bash scripts/bootstrap.sh' or install manually."
  exit 1
fi

if ! kubectl get nodes &>/dev/null; then
  err "Cannot connect to cluster. Is KUBECONFIG set?"
  exit 1
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  err "GITHUB_TOKEN is not set. Export it first:"
  err "  export GITHUB_TOKEN=ghp_..."
  exit 1
fi

# ─── 2. Parse git remote for owner/repo ─────────────────────────────────────
REMOTE=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$REMOTE" ]; then
  err "No git remote 'origin' found. Set up your git remote first."
  exit 1
fi

OWNER=""
REPO=""
if echo "$REMOTE" | grep -q '^git@'; then
  # git@github.com:owner/repo.git
  OWNER=$(echo "$REMOTE" | sed 's|.*:||; s|/.*||')
  REPO=$(echo "$REMOTE" | sed 's|.*/||; s|\.git$||')
elif echo "$REMOTE" | grep -q '^https://'; then
  # https://github.com/owner/repo.git
  OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||; s|/.*||')
  REPO=$(echo "$REMOTE" | sed 's|.*/||; s|\.git$||')
else
  err "Unsupported remote URL format: $REMOTE"
  exit 1
fi

info "GitHub owner: $OWNER, repo: $REPO"

# ─── 3. Commit Flux manifests if uncommitted ────────────────────────────────
if git status --porcelain -- 'clusters/default/' 2>/dev/null | grep -q .; then
  info "Committing Flux manifests to git ..."
  git add -A 'clusters/default/'
  git commit -m "flux: add cluster manifests" || warn "Nothing to commit (all already staged)."
fi

# Check if local is ahead of remote
AHEAD=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
if [ "$AHEAD" -gt 0 ] || git status --porcelain -- 'clusters/default/' 2>/dev/null | grep -q .; then
  info "Pushing to origin ..."
  git push origin HEAD
fi

# ─── 4. Bootstrap Flux ─────────────────────────────────────────────────────
info "Bootstrapping FluxCD ..."
flux bootstrap github \
  --owner="$OWNER" \
  --repository="$REPO" \
  --path="clusters/default" \
  --personal \
  --network-policy=false \
  --token-auth \
  2>&1

# ─── 5. Wait for sync ──────────────────────────────────────────────────────
info "Waiting for Flux to reconcile ..."
for i in $(seq 1 30); do
  if flux check 2>/dev/null; then
    info "Flux is healthy."
    break
  fi
  if [ "$i" -eq 30 ]; then
    warn "Flux health check timed out — continuing anyway."
  fi
  sleep 10
done

info "Waiting for Cilium HelmRelease to be ready ..."
flux wait helmrelease/cilium -n flux-system --for=ready --timeout=5m 2>/dev/null || \
  warn "Cilium HelmRelease not ready yet — check: flux get helmreleases -A"

info "Waiting for Longhorn HelmRelease to be ready ..."
flux wait helmrelease/longhorn -n flux-system --for=ready --timeout=10m 2>/dev/null || \
  warn "Longhorn HelmRelease not ready yet — check: flux get helmreleases -A"

info "Waiting for GatewayAPI Kustomization to be ready ..."
flux wait kustomization/gateway-api-crds -n flux-system --for=ready --timeout=3m 2>/dev/null || \
  warn "GatewayAPI CRDs not ready yet — check: flux get kustomizations -A"

info "── Flux setup complete ───────────────────────────────────────────────"
info "Flux is now managing:"
info "  - Cilium        (adopted existing install)"
info "  - Longhorn      (installing via HelmRelease)"
info "  - GatewayAPI    (CRDs from upstream)"
info "  - L2 IP pool    (CiliumL2AnnouncementPolicy)"
info "  - Playground    (test deployment)"
info ""
info "Monitor with: flux get helmreleases"
info "               flux get kustomizations"
info "               flux logs"
