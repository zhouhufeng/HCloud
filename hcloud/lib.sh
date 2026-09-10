#!/usr/bin/env bash
# HCloud middleware — shared helpers. Source this file; do not execute it.
#
#   HCLOUD_ROOT   repository root
#   HCLOUD_ENV    the platform contract file (default: hcloud/hcloud.env, git-ignored)
#
# Every hcloud/*.sh script starts with:
#   . "$(dirname "$0")/lib.sh"; hc_load_env
# and talks to the cluster only through `kubectl`/`helm` — never through a
# platform-specific tool. That is what keeps the layer portable across bare
# metal, OpenStack VMs, AWS VMs and a Linux VM on a Mac.

HCLOUD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HCLOUD_ENV="${HCLOUD_ENV:-$HCLOUD_ROOT/hcloud/hcloud.env}"
HCLOUD_SECRETS="$HCLOUD_ROOT/docs/Secretes"     # git-ignored (name kept for history)

hc_log()  { echo "==> $*"; }
hc_warn() { echo "  WARNING: $*" >&2; }
hc_die()  { echo "ERROR: $*" >&2; exit 1; }

# Load hcloud.env (if present) and apply defaults for every contract variable.
hc_load_env() {
  if [ -f "$HCLOUD_ENV" ]; then
    set -a; . "$HCLOUD_ENV"; set +a
  else
    hc_warn "no $HCLOUD_ENV — using defaults / exported environment (see hcloud/hcloud.env.example)"
  fi
  : "${HCLOUD_K8S_DISTRO:=k3s}"          # k3s | rke2
  : "${HCLOUD_NODE_ROLE:=server}"        # server | agent
  : "${HCLOUD_HA:=false}"                # true → embedded-etcd cluster (3 servers)
  : "${HCLOUD_SERVER_URL:=}"             # https://<first-server>:6443 for joiners
  : "${HCLOUD_TLS_SAN:=}"                # extra API SANs, space separated
  : "${HCLOUD_K8S_EXTRA_ARGS:=}"         # verbatim distro args
  : "${HCLOUD_STORAGE_DIR:=/var/lib/hcloud/storage}"
  : "${HCLOUD_DOMAIN:=}"                 # public wildcard domain (empty = no public serving)
  : "${HCLOUD_ACME_EMAIL:=}"
  : "${HCLOUD_TUNNEL_NAME:=hcloud}"
  : "${HCLOUD_INGRESS_SVC_TYPE:=LoadBalancer}"
  : "${HCLOUD_USERS:=}"
  : "${HCLOUD_NS:=favor-4ee4be}"         # first application namespace (NERC project)
  mkdir -p "$HCLOUD_SECRETS"
}

hc_require() { command -v "$1" >/dev/null 2>&1 || hc_die "'$1' not found${2:+ — $2}"; }

# Read a secret from the environment variable $1, else from docs/Secretes/$2.
hc_secret() {
  local var="$1" file="$HCLOUD_SECRETS/$2"
  if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; return 0; fi
  if [ -f "$file" ]; then tr -d '\n' < "$file"; return 0; fi
  return 1
}

hc_kubeconfig_path() {
  case "$HCLOUD_K8S_DISTRO" in
    k3s)  echo /etc/rancher/k3s/k3s.yaml ;;
    rke2) echo /etc/rancher/rke2/rke2.yaml ;;
    *)    hc_die "unknown HCLOUD_K8S_DISTRO '$HCLOUD_K8S_DISTRO' (k3s|rke2)" ;;
  esac
}

# Make kubectl usable: prefer the caller's KUBECONFIG, else the distro's.
hc_setup_kubectl() {
  [ -d /var/lib/rancher/rke2/bin ] && export PATH="/var/lib/rancher/rke2/bin:$PATH"
  if [ -z "${KUBECONFIG:-}" ]; then
    local kc; kc="$(hc_kubeconfig_path)"
    [ -r "$kc" ] || hc_die "kubeconfig $kc not readable — run hcloud/10-install-k8s.sh first (or export KUBECONFIG)"
    export KUBECONFIG="$kc"
  fi
  hc_require kubectl
  kubectl get --raw=/readyz >/dev/null 2>&1 || hc_die "cluster API not reachable via $KUBECONFIG"
}

hc_ensure_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    hc_log "Installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
  fi
}

hc_helm_repo() { helm repo add "$1" "$2" >/dev/null 2>&1 || true; helm repo update "$1" >/dev/null; }

hc_ensure_ns() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1" >/dev/null; }

hc_wait_deploy() {  # ns name [timeout]
  kubectl -n "$1" rollout status "deploy/$2" --timeout="${3:-300s}"
}

hc_wait_nodes_ready() {
  local i
  for i in $(seq 1 "${1:-90}"); do
    if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then return 0; fi
    sleep 5
  done
  hc_die "node did not become Ready"
}
