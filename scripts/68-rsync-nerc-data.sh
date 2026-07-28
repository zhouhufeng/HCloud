#!/usr/bin/env bash
# Phase 6.8 (Mac Studio target): copy PVC data from NERC pods to local CRC PVCs.
#
# Prereqs done before running this:
#   - Local CRC cluster up (scripts 60-61 finished)
#   - Migrated manifests applied (scripts/67-migrate-to-crc.py + oc apply)
#   - PVCs exist on both sides with matching names and matching-or-larger size
#   - Workloads on the destination are scaled to 0 (script 67 does this)
#   - You are currently logged in to NERC in a *second* shell (oc context 'nerc')
#     and to the local CRC in this shell (oc context 'crc' / 'crc-admin')
#
# Strategy: for each PVC, spin up a rsync helper pod on each side mounting the
# PVC, then 'oc rsync' from NERC helper -> local helper. Idempotent and
# resumable — rerun to catch up incremental changes before final cutover.
#
# Usage:
#   NERC_KUBECONFIG=~/.kube/config-nerc  \
#   LOCAL_KUBECONFIG=~/.kube/config-crc  \
#   bash scripts/68-rsync-nerc-data.sh <namespace> [pvc-name ...]
# If no pvc-name given, migrates all PVCs listed in raw/persistentvolumeclaim.yaml.
set -euo pipefail

: "${NERC_KUBECONFIG:?set NERC_KUBECONFIG (kubeconfig with the NERC token)}"
: "${LOCAL_KUBECONFIG:?set LOCAL_KUBECONFIG (kubeconfig for local CRC)}"
NS="${1:-favor-4ee4be}"; shift || true
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$REPO_ROOT/docs/Secretes/migration/$NS/raw"
PVC_FILE="$RAW/persistentvolumeclaim.yaml"
[ -f "$PVC_FILE" ] || PVC_FILE="$RAW/pvc.yaml"
[ -f "$PVC_FILE" ] || { echo "ERROR: no raw PVC export at $RAW (pvc.yaml or persistentvolumeclaim.yaml)"; exit 1; }

OC_NERC=(oc --kubeconfig "$NERC_KUBECONFIG" -n "$NS")
OC_LOCAL=(oc --kubeconfig "$LOCAL_KUBECONFIG" -n "$NS")

if [ $# -gt 0 ]; then
  PVCS=("$@")
else
  # extract PVC names from the raw export
  mapfile -t PVCS < <(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$PVC_FILE'))
for i in (d.get('items') or [d]):
    print(i['metadata']['name'])
")
fi

# Rsync helper pod template: alpine with rsync + a mount for a specific PVC.
helper_pod () {
  local pod_name="$1" pvc="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  labels: {hcloud.local/role: rsync-helper}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: rsync
      image: alpine:3.20
      command: ["sh","-c","apk add --no-cache rsync openssh >/dev/null 2>&1; sleep infinity"]
      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: false}
      volumeMounts:
        - {name: data, mountPath: /data}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: ${pvc}}
EOF
}

for PVC in "${PVCS[@]}"; do
  echo "===================================================================="
  echo "== PVC: $PVC"
  echo "===================================================================="

  # Local helper
  if ! "${OC_LOCAL[@]}" get pod "rsync-local-$PVC" >/dev/null 2>&1; then
    echo "==> Starting local helper pod"
    helper_pod "rsync-local-$PVC" "$PVC" | "${OC_LOCAL[@]}" apply -f -
    "${OC_LOCAL[@]}" wait pod "rsync-local-$PVC" --for=condition=Ready --timeout=120s
  fi

  # NERC helper
  if ! "${OC_NERC[@]}" get pod "rsync-nerc-$PVC" >/dev/null 2>&1; then
    echo "==> Starting NERC helper pod"
    helper_pod "rsync-nerc-$PVC" "$PVC" | "${OC_NERC[@]}" apply -f -
    "${OC_NERC[@]}" wait pod "rsync-nerc-$PVC" --for=condition=Ready --timeout=180s
  fi

  echo "==> Copying $PVC (NERC -> local); resumable, may take hours for big PVCs"
  # oc rsync from a NERC pod's /data to a local tmpdir, then oc rsync into local pod.
  # Two-hop is slower than direct but handles the two-cluster case cleanly.
  TMP=$(mktemp -d "/Volumes/HSZ/.rsync-$PVC.XXXX")
  "${OC_NERC[@]}"  rsync "rsync-nerc-$PVC:/data/"  "$TMP/"       --progress=true --delete=false
  "${OC_LOCAL[@]}" rsync "$TMP/"                   "rsync-local-$PVC:/data/" --progress=true --delete=false
  rm -rf "$TMP"
  echo "==> $PVC copy pass complete"
done

echo
echo "All PVCs copied. Re-run this script for a quick incremental catchup right"
echo "before you scale workloads up on CRC and scale them down on NERC."
