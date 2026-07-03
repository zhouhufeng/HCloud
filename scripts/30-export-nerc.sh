#!/usr/bin/env bash
# Phase 3: export everything from a NERC OpenShift namespace before the platform terminates.
# Usage: oc login <NERC API URL> first, then: ./30-export-nerc.sh <namespace> [more namespaces...]
# Output lands in migration/<namespace>/ ready for scrubbing and re-apply on HCloud.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { echo "usage: $0 <namespace> [namespace...]"; exit 1; }

for ns in "$@"; do
  out="$REPO_ROOT/migration/$ns"
  mkdir -p "$out"
  echo "==> Exporting namespace $ns to $out"

  for kind in deployment deploymentconfig statefulset daemonset cronjob job \
              service route configmap secret pvc serviceaccount rolebinding \
              imagestream buildconfig hpa networkpolicy; do
    if oc get "$kind" -n "$ns" -o name 2>/dev/null | grep -q .; then
      oc get "$kind" -n "$ns" -o yaml > "$out/$kind.yaml"
      echo "    $kind: $(oc get "$kind" -n "$ns" -o name | wc -l)"
    fi
  done

  # Record images in use, for mirroring with skopeo/oc image mirror.
  oc get pods -n "$ns" -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
    | sort -u > "$out/images.txt" || true
  echo "    images: $(wc -l < "$out/images.txt")"
done

echo
echo "Next: scrub cluster-specific fields (status, uid, resourceVersion, clusterIP,"
echo "NERC route hosts, storageClassName) before applying to HCloud. PVC *data* must be"
echo "copied separately with 'oc rsync' while NERC pods are still running."
