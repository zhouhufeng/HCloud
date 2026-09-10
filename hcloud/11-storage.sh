#!/usr/bin/env bash
# HCloud middleware · 11 — storage classes.
#
# Gives every application the same three StorageClass names on every platform:
#   local-path                              dynamic PVs under HCLOUD_STORAGE_DIR (default class)
#   hcloud-data                             static PVs for pre-existing/migrated data (apps/…/60-resume.sh)
#   ocs-external-storagecluster-ceph-rbd    NERC's class name, aliased → unmodified NERC manifests bind
#
# The platform layer decides WHAT is behind HCLOUD_STORAGE_DIR (a 22 TB HDD, an
# NVMe RAID10, a Cinder volume, an EBS volume). Platforms with a real CSI driver
# (OpenStack) may re-point the alias afterwards — see platform/openstack/20-cloud-integration.sh.
# Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env; hc_setup_kubectl
hc_require python3

sudo mkdir -p "$HCLOUD_STORAGE_DIR"
hc_log "PV directory: $HCLOUD_STORAGE_DIR ($(df -h "$HCLOUD_STORAGE_DIR" | awk 'NR==2{print $4" free on "$1}'))"

# k3s bundles local-path-provisioner in kube-system; rke2 does not ship it.
if kubectl -n kube-system get deploy local-path-provisioner >/dev/null 2>&1; then
  LP_NS=kube-system
else
  LP_NS=local-path-storage
  hc_log "Installing rancher local-path-provisioner"
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
  hc_wait_deploy "$LP_NS" local-path-provisioner
fi

hc_log "Pointing local-path at $HCLOUD_STORAGE_DIR"
PATCH="$(python3 - "$HCLOUD_STORAGE_DIR" <<'PY'
import json, sys
cfg = {"nodePathMap": [{"node": "DEFAULT_PATH_FOR_NON_LISTED_NODES", "paths": [sys.argv[1]]}]}
print(json.dumps({"data": {"config.json": json.dumps(cfg)}}))
PY
)"
kubectl -n "$LP_NS" patch configmap local-path-config --type merge -p "$PATCH" >/dev/null
kubectl -n "$LP_NS" rollout restart deploy/local-path-provisioner >/dev/null
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null

hc_log "StorageClass hcloud-data (static PVs for migrated data)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hcloud-data
  annotations:
    hcloud.io/notes: "Static hostPath PVs created by apps/nerc-migration/60-resume.sh bind here."
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

hc_log "StorageClass alias ocs-external-storagecluster-ceph-rbd → local-path"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-external-storagecluster-ceph-rbd
  annotations:
    hcloud.io/notes: "NERC storage-class name; PVCs exported from NERC bind unchanged."
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

kubectl get storageclass
echo
echo "Done. Next: hcloud/12-ingress-tls.sh"
