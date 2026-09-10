#!/usr/bin/env bash
# Application layer · 60 — resume the whole migrated stack on a fresh host from this folder.
#
# Prereq: this HCloud folder present WITH  cluster-data/<pvc-name>/  (the migrated PVC
# data, ~7 TiB, git-ignored) and docs/Secretes/migration/<ns>/deploy/*.json (git-ignored).
# Both travel on the drive. Runs the middleware (10, 11) if the cluster is not up, creates
# static hostPath PVs of class hcloud-data pointing at cluster-data/, binds the PVCs,
# applies config + workloads, scales up. Works on any platform the middleware runs on.
# Idempotent-ish. Needs sudo for the middleware steps.
#   HCLOUD_DATA_DIR  override the data directory (e.g. an NVMe tier on the Dell blades)
set -euo pipefail
. "$(dirname "$0")/../../hcloud/lib.sh"; hc_load_env
NS="${1:-$HCLOUD_NS}"
CDATA="${HCLOUD_DATA_DIR:-$HCLOUD_ROOT/cluster-data}"
DEPLOY="$HCLOUD_SECRETS/migration/$NS/deploy"
[ -d "$CDATA" ]  || hc_die "$CDATA missing (mount the data drive / copy the folder)"
[ -d "$DEPLOY" ] || hc_die "$DEPLOY missing (deploy manifests not present)"

hc_log "1/6 Middleware: Kubernetes + storage classes (skipped if already up)"
if ! KUBECONFIG="${KUBECONFIG:-$(hc_kubeconfig_path)}" kubectl get --raw=/readyz >/dev/null 2>&1; then
  bash "$HCLOUD_ROOT/hcloud/10-install-k8s.sh"
  bash "$HCLOUD_ROOT/hcloud/11-storage.sh"
fi
hc_setup_kubectl; hc_wait_nodes_ready

hc_log "2/6 Namespace $NS"; hc_ensure_ns "$NS"

hc_log "3/6 Static PVs (hostPath, class hcloud-data) → $CDATA"
python3 - "$DEPLOY/persistentvolumeclaim.json" "$CDATA" <<'PY' | kubectl apply -f - >/dev/null
import json,sys,os
caps={i['metadata']['name']: i['spec']['resources']['requests']['storage']
      for i in json.load(open(sys.argv[1]))['items']}
cdata=sys.argv[2]; items=[]
for vol in sorted(os.listdir(cdata)):
    p=os.path.join(cdata,vol)
    if not os.path.isdir(p): continue
    items.append({'apiVersion':'v1','kind':'PersistentVolume','metadata':{'name':vol},
      'spec':{'capacity':{'storage':caps.get(vol,'100Gi')},'accessModes':['ReadWriteOnce'],
      'persistentVolumeReclaimPolicy':'Retain','storageClassName':'hcloud-data',
      'hostPath':{'path':p}}})
print(json.dumps({'apiVersion':'v1','kind':'List','items':items}))
PY

hc_log "4/6 PVCs bound to those PVs"
python3 - "$DEPLOY/persistentvolumeclaim.json" "$NS" <<'PY' | kubectl apply -f - >/dev/null
import json,sys
d=json.load(open(sys.argv[1])); ns=sys.argv[2]
for i in d['items']:
    n=i['metadata']['name']
    i['metadata']={'name':n,'namespace':ns}; i.pop('status',None)
    i['spec']['storageClassName']='hcloud-data'; i['spec']['volumeName']=n
print(json.dumps(d))
PY

hc_log "5/6 Config + workloads"
for f in secret configmap serviceaccount service ingress statefulset deployment; do
  [ -f "$DEPLOY/$f.json" ] && kubectl apply -n "$NS" -f "$DEPLOY/$f.json" >/dev/null && echo "   applied $f"
done

hc_log "6/6 Scale to original replicas"
HCLOUD_MANIFEST_VARIANT=clean bash "$HCLOUD_ROOT/apps/nerc-migration/50-scale-up.sh" "$NS" || hc_warn "scale-up skipped (no _replicas.json?)"

cat <<EOF

Done. Watch: kubectl -n $NS get pods -w
Production notes (Dell blades): put DB volumes (ClickHouse/ES/RocksDB/Postgres/Kuzu) on the
NVMe tier and MinIO on bulk — point HCLOUD_DATA_DIR (or per-volume symlinks in cluster-data/)
accordingly. Remaining migration work (ES big indices, ClickHouse last ~13 %) is tracked in
docs/Secretes/migration/STATUS.md and docs/MIGRATION.md.
EOF
