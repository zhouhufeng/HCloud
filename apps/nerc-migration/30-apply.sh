#!/usr/bin/env bash
# Application layer · 30 — apply the converted manifests to the HCloud cluster.
# Workloads land at replicas: 0; PVCs bind (local-path is WaitForFirstConsumer, so
# they bind when the first mover pod / workload mounts them).
# Usage: 30-apply.sh [namespace]      (KUBECONFIG from the middleware if unset)
set -euo pipefail
. "$(dirname "$0")/../../hcloud/lib.sh"; hc_load_env; hc_setup_kubectl
NS="${1:-$HCLOUD_NS}"
CLEAN="$HCLOUD_SECRETS/migration/$NS/clean"
[ -d "$CLEAN" ] || hc_die "$CLEAN missing — run 20-convert-manifests.py --ns $NS"

hc_ensure_ns "$NS"
for f in "$CLEAN"/[0-9]*.yaml; do
  echo "   applying $(basename "$f")"; kubectl apply -n "$NS" -f "$f" >/dev/null
done
echo
kubectl -n "$NS" get pvc,svc,ingress
echo "Done. Copy data next (40-migrate-volume.sh / 41-migrate-bigvol.sh), then 50-scale-up.sh $NS"
