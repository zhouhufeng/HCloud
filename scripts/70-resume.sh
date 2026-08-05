#!/usr/bin/env bash
# Resume the whole migrated HCloud stack on a fresh machine, straight from this folder.
# Prereq: this HCloud folder present (drive mounted or copied) WITH cluster-data/ and
# docs/Secretes/migration/favor-4ee4be/deploy/ (both travel on the drive, git-ignored).
# Installs RKE2, re-attaches the migrated PVC data via static hostPath PVs, applies all
# manifests, scales workloads up. Idempotent-ish. Needs sudo.
set -euo pipefail

FOLDER="$(cd "$(dirname "$0")/.." && pwd)"
CDATA="$FOLDER/cluster-data"
DEPLOY="$FOLDER/docs/Secretes/migration/favor-4ee4be/deploy"
NS=favor-4ee4be
[ -d "$CDATA" ]  || { echo "ERROR: $CDATA missing (mount the data drive / copy the folder)"; exit 1; }
[ -d "$DEPLOY" ] || { echo "ERROR: $DEPLOY missing (deploy manifests not present)"; exit 1; }

echo "==> 1/6 Install RKE2 (if not already running)"
if ! sudo systemctl is-active --quiet rke2-server 2>/dev/null; then
  bash "$FOLDER/scripts/40-install-rke2.sh"
fi
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
K="/var/lib/rancher/rke2/bin/kubectl"
for i in $(seq 1 60); do "$K" get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done

echo "==> 2/6 Namespace"
"$K" create namespace "$NS" --dry-run=client -o yaml | "$K" apply -f -

echo "==> 3/6 Static PVs (hostPath) bound to the migrated data in cluster-data/"
python3 - "$DEPLOY/persistentvolumeclaim.json" "$CDATA" <<'PY' | "$K" apply -f -
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

echo "==> 4/6 PVCs bound to those PVs"
python3 - "$DEPLOY/persistentvolumeclaim.json" <<'PY' | "$K" apply -f -
import json,sys
d=json.load(open(sys.argv[1]))
for i in d['items']:
    n=i['metadata']['name']
    i['metadata']={'name':n,'namespace':'favor-4ee4be'}
    i.pop('status',None)
    i['spec']['storageClassName']='hcloud-data'
    i['spec']['volumeName']=n
print(json.dumps(d))
PY

echo "==> 5/6 Config + workloads"
for f in secret configmap serviceaccount service ingress statefulset deployment; do
  [ -f "$DEPLOY/$f.json" ] && "$K" apply -n "$NS" -f "$DEPLOY/$f.json" >/dev/null && echo "   applied $f"
done

echo "==> 6/6 Scale workloads to original replicas"
REPL="$FOLDER/docs/Secretes/migration/favor-4ee4be/clean/_replicas.json"
if [ -f "$REPL" ]; then
  python3 -c "import json;print('\n'.join('%s %s'%(k,v) for k,v in json.load(open('$REPL')).items()))" | while read kind_name n; do
    kind="${kind_name%%/*}"; name="${kind_name##*/}"
    "$K" -n "$NS" scale "$kind" "$name" --replicas="$n" 2>/dev/null && echo "   $kind/$name -> $n"
  done
fi

cat <<EOF

Done. Watch it come up:
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  $K -n $NS get pods -w

Notes for the production rack server:
  - Put DB volumes (ClickHouse/ES/RocksDB/Postgres/Kuzu) on NVMe; MinIO on HDD/bulk.
  - Elasticsearch: the 2 big indices (biokg, fav_variants) need mappings copied from
    NERC before reindex completes — see docs/Secretes/migration/STATUS.md.
  - ClickHouse: last ~13% needs a brief NERC quiesce (cutover) for a consistent 1:1.
EOF
