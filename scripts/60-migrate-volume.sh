#!/usr/bin/env bash
# Migrate one live NERC pod volume into the matching local RKE2 PVC via a mover pod + tar stream.
# Best-effort/live copy (NERC stays up); a final cutover delta-sync gives the consistent 1:1.
# Usage: 60-migrate-volume.sh <name> <nerc_pod> <nerc_path> <local_pvc> [nerc_container]
set -uo pipefail
NAME=$1; NPOD=$2; NPATH=$3; PVC=$4; NCON=${5:-}
OC=$(find "$HOME/.crc" -name oc -type f 2>/dev/null | head -1); [ -z "$OC" ] && OC=$(command -v oc)
MIG=/media/hzhou/HSA/Sync/HCloud/docs/Secretes/migration
NSA=("$OC" --kubeconfig "$MIG/nerc-sa.kubeconfig" -n favor-4ee4be exec)
[ -n "$NCON" ] && NSA+=(-c "$NCON")
K=(kubectl -n favor-4ee4be)
MOVER="mover-$NAME"

"${K[@]}" apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata: {name: $MOVER, namespace: favor-4ee4be, labels: {role: mover}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
  - name: mover
    image: alpine:3
    command: ["sleep","infinity"]
    volumeMounts: [{name: d, mountPath: /dest}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: $PVC}}]
POD
"${K[@]}" wait --for=condition=Ready "pod/$MOVER" --timeout=180s || { echo "[$NAME] mover not ready"; exit 1; }

ok=0
for attempt in 1 2 3 4 5; do
  echo "[$NAME] attempt $attempt start $(date -u +%H:%M:%S)"
  set -o pipefail
  if "${NSA[@]}" "$NPOD" -- tar cf - -C "$NPATH" . 2>/dev/null \
       | "${K[@]}" exec -i "$MOVER" -- tar xf - -C /dest ; then
    echo "[$NAME] tar stream OK"; ok=1; break
  fi
  echo "[$NAME] attempt $attempt failed; retry in 30s"; sleep 30
done

echo "[$NAME] === verify ==="
echo -n "[$NAME] NERC : "; "${NSA[@]}" "$NPOD" -- du -sh "$NPATH" 2>/dev/null | awk '{print $1}'
echo -n "[$NAME] local: "; "${K[@]}" exec "$MOVER" -- du -sh /dest 2>/dev/null | awk '{print $1}'
[ "$ok" = 1 ] && echo "[$NAME] DONE" || echo "[$NAME] INCOMPLETE after retries"
