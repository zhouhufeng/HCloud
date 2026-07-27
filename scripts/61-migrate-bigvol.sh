#!/usr/bin/env bash
# Sharded parallel tar migration for a big live volume (immutable-file stores: ClickHouse, RocksDB).
# One tar stream per 2nd-level subdir, PAR in parallel, each shard retried. Resumable at shard grain.
# Usage: PAR=6 61-migrate-bigvol.sh <name> <nerc_pod> <nerc_path> <local_pvc> [nerc_container]
set -uo pipefail
NAME=$1; NPOD=$2; NPATH=$3; PVC=$4; NCON=${5:-}; PAR=${PAR:-6}
OC=$(find "$HOME/.crc" -name oc -type f 2>/dev/null | head -1); [ -z "$OC" ] && OC=$(command -v oc)
MIG=/media/hzhou/HSA/Sync/HCloud/docs/Secretes/migration
NSA=("$OC" --kubeconfig "$MIG/nerc-sa.kubeconfig" -n favor-4ee4be exec); [ -n "$NCON" ] && NSA+=(-c "$NCON")
K=(kubectl -n favor-4ee4be); MOVER="mover-$NAME"

"${K[@]}" get pod "$MOVER" >/dev/null 2>&1 || "${K[@]}" apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata: {name: $MOVER, namespace: favor-4ee4be, labels: {role: mover}}
spec:
  restartPolicy: Never
  containers: [{name: mover, image: alpine:3, command: ["sleep","infinity"], volumeMounts: [{name: d, mountPath: /dest}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: $PVC}}]
POD
"${K[@]}" wait --for=condition=Ready "pod/$MOVER" --timeout=180s || exit 1

# Build a 2-level shard list (dir/subdir) so parallelism is fine-grained; fall back to 1-level.
mapfile -t SHARDS < <("${NSA[@]}" "$NPOD" -- sh -c "cd '$NPATH' && find . -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sed 's|^\./||' | head -2000")
[ "${#SHARDS[@]}" -lt 2 ] && mapfile -t SHARDS < <("${NSA[@]}" "$NPOD" -- sh -c "cd '$NPATH' && find . -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|^\./||'")
echo "[$NAME] $(date -u +%H:%M:%S) shards=${#SHARDS[@]} parallelism=$PAR"

export OC MIG NPOD NPATH NCON MOVER
copy_one(){
  s="$1"
  OCC=("$OC" --kubeconfig "$MIG/nerc-sa.kubeconfig" -n favor-4ee4be exec); [ -n "$NCON" ] && OCC+=(-c "$NCON")
  for a in 1 2 3; do
    set -o pipefail
    if "${OCC[@]}" "$NPOD" -- tar cf - -C "$NPATH" "$s" 2>/dev/null \
        | kubectl -n favor-4ee4be exec -i "$MOVER" -- sh -c "mkdir -p /dest/\"\$(dirname '$s')\"; tar xf - -C /dest"; then
      return 0; fi
    sleep 20
  done
  echo "[$NAME] SHARD FAILED: $s"
}
export -f copy_one
printf '%s\n' "${SHARDS[@]}" | xargs -P "$PAR" -I{} bash -c 'copy_one "$@"' _ {}

# top-level loose files (not in any subdir)
"${NSA[@]}" "$NPOD" -- sh -c "cd '$NPATH' && find . -maxdepth 1 -type f 2>/dev/null | tar cf - -T - 2>/dev/null" \
  | "${K[@]}" exec -i "$MOVER" -- tar xf - -C /dest 2>/dev/null
echo -n "[$NAME] NERC : "; "${NSA[@]}" "$NPOD" -- du -sh "$NPATH" 2>/dev/null | awk '{print $1}'
echo -n "[$NAME] local: "; "${K[@]}" exec "$MOVER" -- du -sh /dest 2>/dev/null | awk '{print $1}'
echo "[$NAME] sharded pass complete $(date -u +%H:%M:%S)"
