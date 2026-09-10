#!/usr/bin/env bash
# HCloud middleware · 15 — monitoring (NERC cluster-monitoring parity).
#
# kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node/kube exporters).
# With HCLOUD_DOMAIN set, Grafana is published at grafana.HCLOUD_DOMAIN through the
# standard ingress; the admin password is written to docs/Secretes/grafana-admin.txt.
# Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env; hc_setup_kubectl; hc_ensure_helm

PW_FILE="$HCLOUD_SECRETS/grafana-admin.txt"
if [ ! -s "$PW_FILE" ]; then umask 077; openssl rand -base64 18 | tr -d '/+=' > "$PW_FILE"; fi
PW="$(tr -d '\n' < "$PW_FILE")"

INGRESS=()
if [ -n "$HCLOUD_DOMAIN" ]; then
  INGRESS=(--set grafana.ingress.enabled=true
           --set grafana.ingress.ingressClassName=nginx
           --set "grafana.ingress.hosts[0]=grafana.${HCLOUD_DOMAIN}")
fi

hc_log "kube-prometheus-stack"
hc_helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword="$PW" \
  --set prometheus.prometheusSpec.retention="${HCLOUD_PROM_RETENTION:-30d}" \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${HCLOUD_PROM_SIZE:-100Gi}" \
  "${INGRESS[@]}" --wait --timeout 10m

echo
echo "Done. Grafana admin password: $PW_FILE"
[ -n "$HCLOUD_DOMAIN" ] && echo "Grafana: https://grafana.${HCLOUD_DOMAIN}" \
  || echo "Grafana (LAN): kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
