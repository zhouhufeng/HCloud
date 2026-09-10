#!/usr/bin/env bash
# HCloud middleware · 10 — install Kubernetes on this host.
#
# Platform-agnostic: runs on any Linux host the platform layer hands over (bare
# metal, an OpenStack or AWS VM, a Lima VM on a Mac). Reads hcloud/hcloud.env.
#
#   HCLOUD_K8S_DISTRO      k3s (standard) | rke2 (kept for the validated Linux `pc` PoC)
#   HCLOUD_NODE_ROLE       server | agent
#   HCLOUD_HA=true         first server: --cluster-init (embedded etcd; add 2 more servers)
#   HCLOUD_SERVER_URL      joiners: https://<first-server>:6443
#   HCLOUD_TLS_SAN         extra API SANs
#   HCLOUD_K8S_EXTRA_ARGS  passed through verbatim (platform-specific flags live in platform/)
#
# The bundled ingress (traefik on k3s, rke2-ingress-nginx on rke2) is disabled so
# that 12-ingress-tls.sh installs ONE ingress-nginx identically on every platform.
# Idempotent: a running node is left alone (HCLOUD_FORCE=1 re-runs the installer).
# Requires sudo.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env
hc_require curl

# ---- node token ------------------------------------------------------------
TOKEN_FILE="$HCLOUD_SECRETS/k8s-node-token"
if ! TOKEN="$(hc_secret HCLOUD_K8S_TOKEN k8s-node-token)"; then
  if [ "$HCLOUD_NODE_ROLE" = server ] && [ -z "$HCLOUD_SERVER_URL" ]; then
    hc_log "Generating node token → $TOKEN_FILE (copy it to every joining node)"
    TOKEN="$(openssl rand -hex 32)"; umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
  else
    hc_die "joining node needs HCLOUD_K8S_TOKEN or $TOKEN_FILE from the first server"
  fi
fi
[ "$HCLOUD_NODE_ROLE" = server ] || [ -n "$HCLOUD_SERVER_URL" ] || hc_die "agents need HCLOUD_SERVER_URL"

SVC="$HCLOUD_K8S_DISTRO"; [ "$HCLOUD_NODE_ROLE" = agent ] && SVC="$HCLOUD_K8S_DISTRO-agent"
if sudo systemctl is-active --quiet "$SVC" 2>/dev/null && [ "${HCLOUD_FORCE:-0}" != 1 ]; then
  hc_log "$SVC already running — skipping install (HCLOUD_FORCE=1 to re-run)"
else
  case "$HCLOUD_K8S_DISTRO" in
  # ---------------------------------------------------------------- k3s ----
  k3s)
    ARGS=()
    if [ "$HCLOUD_NODE_ROLE" = server ]; then
      ARGS+=(--disable traefik --write-kubeconfig-mode 0644)
      for san in $HCLOUD_TLS_SAN; do ARGS+=(--tls-san "$san"); done
      if [ -n "$HCLOUD_SERVER_URL" ]; then ARGS+=(--server "$HCLOUD_SERVER_URL")
      elif [ "$HCLOUD_HA" = true ]; then ARGS+=(--cluster-init); fi
    else
      ARGS+=(--server "$HCLOUD_SERVER_URL")
    fi
    # shellcheck disable=SC2206
    ARGS+=($HCLOUD_K8S_EXTRA_ARGS)
    hc_log "Installing k3s ($HCLOUD_NODE_ROLE): ${ARGS[*]}"
    curl -sfL https://get.k3s.io | sudo K3S_TOKEN="$TOKEN" INSTALL_K3S_CHANNEL="${HCLOUD_K3S_CHANNEL:-stable}" \
      sh -s - "$HCLOUD_NODE_ROLE" "${ARGS[@]}"
    ;;
  # --------------------------------------------------------------- rke2 ----
  rke2)
    hc_log "Installing rke2 ($HCLOUD_NODE_ROLE)"
    if [ ! -x /usr/local/bin/rke2 ] && [ ! -x /var/lib/rancher/rke2/bin/rke2 ]; then
      curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="$HCLOUD_NODE_ROLE" sh -
    fi
    sudo mkdir -p /etc/rancher/rke2
    {
      echo "token: $TOKEN"
      [ -n "$HCLOUD_SERVER_URL" ] && echo "server: $HCLOUD_SERVER_URL"
      if [ "$HCLOUD_NODE_ROLE" = server ]; then
        echo 'write-kubeconfig-mode: "0644"'
        echo "disable:"; echo "  - rke2-ingress-nginx"
        if [ -n "$HCLOUD_TLS_SAN" ]; then echo "tls-san:"; for san in $HCLOUD_TLS_SAN; do echo "  - $san"; done; fi
      fi
      # extra args as "key: value" lines, e.g. HCLOUD_K8S_EXTRA_ARGS="node-label=hcloud.role=db"
      for kv in $HCLOUD_K8S_EXTRA_ARGS; do echo "${kv%%=*}: ${kv#*=}"; done
    } | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
    sudo chmod 600 /etc/rancher/rke2/config.yaml
    sudo systemctl enable --now "$SVC.service"
    ;;
  *) hc_die "unknown HCLOUD_K8S_DISTRO '$HCLOUD_K8S_DISTRO'" ;;
  esac
fi

if [ "$HCLOUD_NODE_ROLE" = server ]; then
  hc_log "Waiting for node Ready"
  hc_setup_kubectl; hc_wait_nodes_ready
  kubectl get nodes -o wide
  cat <<EOF

Kubernetes ($HCLOUD_K8S_DISTRO) is up.
  kubeconfig : $KUBECONFIG
  node token : $TOKEN_FILE  (needed by hcloud/10-install-k8s.sh on joining nodes)
Next: hcloud/11-storage.sh → 12-ingress-tls.sh → 13-public-tunnel.sh → 14-tenants.sh → 15-monitoring.sh
EOF
else
  echo "Agent joined $HCLOUD_SERVER_URL. Verify from a server: kubectl get nodes"
fi
