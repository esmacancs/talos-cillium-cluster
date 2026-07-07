# ─── Talos + Vagrant + Cilium automation ─────────────────────────────────────

-include .env

CLUSTER_NAME ?= talos
CONTROL_COUNT ?= 3
WORKER_COUNT ?= 1
CP_CPUS      ?= 2
CP_MEMORY    ?= 2048
WORKER_CPUS  ?= 1
WORKER_MEMORY?= 1024
DISK_SIZE    ?= 10G
SUBNET       ?= 192.168.121
VIP          ?= $(SUBNET).100
DEPLOY_TIMEOUT ?= 40m
FLUX_TIMEOUT   ?= 10m

export CLUSTER_NAME CONTROL_COUNT WORKER_COUNT
export CP_CPUS CP_MEMORY WORKER_CPUS WORKER_MEMORY DISK_SIZE SUBNET VIP
export LONGHORN_DISK_SIZE DEPLOY_TIMEOUT FLUX_TIMEOUT

# ─── Phony targets ────────────────────────────────────────────────────────────
.PHONY: help bootstrap up deploy status down destroy clean
.PHONY: deploy-cilium install-longhorn setup-flux full-deploy

# ─── Help ─────────────────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ─── Prerequisites & VMs ──────────────────────────────────────────────────────
bootstrap: ## [sudo] Install all prerequisites (Vagrant, talosctl, kubectl, flux, etc.)
	sudo bash scripts/bootstrap.sh

registry-mirror: ## Start local container registry mirrors (speeds up image pulls)
	bash scripts/setup-registry-mirror.sh

up: ## Start VMs with vagrant-libvirt
	vagrant up --provider=libvirt

status: ## Show VM status
	@echo "=== Vagrant status ==="
	vagrant status
	@echo ""
	@echo "=== VM IPs ==="
	@scripts/fetch-ips.sh

# ─── Talos cluster ────────────────────────────────────────────────────────────
deploy: ## Deploy Talos cluster (generate config, bootstrap, apply workers)
	bash scripts/deploy.sh

deploy-cilium: ## Deploy Talos + install Cilium CNI imperatively
	bash scripts/deploy.sh --cilium

install-longhorn: ## Install Longhorn imperatively (deprecated — use setup-flux instead)
	bash scripts/install-longhorn.sh

# ─── FluxCD (GitOps) ──────────────────────────────────────────────────────────
setup-flux: ## Bootstrap FluxCD + manage Cilium/Longhorn/resources via GitOps
	bash scripts/setup-flux.sh

full-deploy: ## Unattended full deploy: VMs + Talos + Cilium + FluxCD (everything)
	@echo "=== Phase 1: VMs ==="
	vagrant up --provider=libvirt
	@echo ""
	@echo "=== Phase 2: Talos + Cilium ==="
	timeout $(DEPLOY_TIMEOUT) bash scripts/deploy.sh --cilium || \
		echo "[WARN] deploy.sh exited with $$? (timeout: $(DEPLOY_TIMEOUT)) — check 'make status'"
	@echo ""
	@echo "=== Phase 3: FluxCD ==="
	timeout $(FLUX_TIMEOUT) bash scripts/setup-flux.sh || \
		echo "[WARN] setup-flux.sh exited with $$? (timeout: $(FLUX_TIMEOUT)) — run 'make setup-flux' to retry"
	@echo ""
	@echo "=== full-deploy complete ==="
	@echo "Check status: make status && make health"

# ─── Utilities ────────────────────────────────────────────────────────────────
kubeconfig: ## Export paths for kubeconfig and talosconfig
	$(eval KUBECONFIG:=$(shell pwd)/kubeconfig)
	$(eval TALOSCONFIG:=$(shell pwd)/talosconfig)
	@echo "export KUBECONFIG=$(KUBECONFIG)"
	@echo "export TALOSCONFIG=$(TALOSCONFIG)"

health: ## Check Talos & K8s cluster health
	@echo "--- Talos health ---"
	-talosctl health
	@echo ""
	@echo "--- Nodes ---"
	-kubectl get nodes -o wide

destroy: ## Destroy all VMs (keeps downloaded ISO)
	vagrant destroy -f

clean: destroy ## Destroy VMs + remove generated configs and ISO
	-rm -f talosconfig controlplane.yaml worker.yaml kubeconfig
	-rm -f /tmp/metal-amd64.iso
	@echo "Cleanup done."
