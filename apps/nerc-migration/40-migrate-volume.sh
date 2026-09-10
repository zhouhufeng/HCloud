#!/usr/bin/env bash
# Application layer · 40 — copy ONE live NERC pod volume into the matching HCloud PVC (mover pod + tar stream).
# Live/best-effort copy while NERC stays up; a final cutover delta pass gives the consistent 1:1.
# Needs: oc + docs/Secretes/migration/nerc-sa.kubeconfig (NERC token); kubectl → HCloud (KUBECONFIG).
# Usage: 40-migrate-volume.sh <name> <nerc_pod> <nerc_path> <local_pvc> [nerc_container]
set -uo pipefail
NAME=$1; NPOD=$2; NPATH=$3; PVC=$4; NCON=${5:-}
OC="${OC:-$(command -v oc || find "$HOME/.crc" -name oc -type f 2>/dev/null | head -1)}"; [ -n "$OC" ] || { echo "ERROR: oc CLI needed to exec into NERC pods"; exit 1; }
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; MIG="$REPO_ROOT/docs/Secretes/migration"
NS="${HCLOUD_NS:-favor-4ee4be}"
NSA=("$OC" --kubeconfig "$MIG/nerc-sa.kubeconfig" -n "$NS" exec)
[ -n "$NCON" ] && NSA+=(-c "$NCON")
K=(kubectl -n "$NS")
MOVER="mover-$NAME"

"${K[@]}" apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata: {name: $MOVER, namespace: $NS, labels: {role: mover}}
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
