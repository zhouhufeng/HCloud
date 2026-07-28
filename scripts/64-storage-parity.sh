#!/usr/bin/env bash
# Phase 6.4 (Mac Studio target): NERC storage parity.
#
# 1. StorageClass alias: NERC PVCs reference storageClassName:
#      ocs-external-storagecluster-ceph-rbd
#    which doesn't exist on CRC. We create a StorageClass with that exact name
#    backed by CRC's default provisioner, so NERC PVCs bind unchanged.
#
# 2. MinIO operator: gives S3-compatible object storage (NERC's object-storage
#    story on OpenShift).
#
# 3. Not attempted here (honest gaps vs NERC):
#      - Ceph RBD snapshots / cross-node HA (single-node cluster)
#      - RWX volumes (NERC also doesn't offer this on OpenShift)
#      - GPU-backed workloads (Apple Silicon Metal is not exposed to containers)
set -euo pipefail

if [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null; then eval "$(crc oc-env)"; fi
command -v oc >/dev/null || { echo "ERROR: oc missing"; exit 1; }

echo "==> Detecting CRC default StorageClass"
DEFAULT_SC=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | head -1)
[ -n "$DEFAULT_SC" ] || DEFAULT_SC=$(oc get sc -o jsonpath='{.items[0].metadata.name}')
PROV=$(oc get sc "$DEFAULT_SC" -o jsonpath='{.provisioner}')
echo "  default SC = ${DEFAULT_SC} (provisioner: ${PROV})"

echo "==> Creating NERC-name alias StorageClass 'ocs-external-storagecluster-ceph-rbd'"
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-external-storagecluster-ceph-rbd
  annotations:
    hcloud.local/notes: "NERC-name alias; PVCs referencing this class bind on CRC unchanged. Backed by ${PROV}."
provisioner: ${PROV}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

echo "==> Installing MinIO operator (object storage)"
oc get ns minio-operator >/dev/null 2>&1 || oc create ns minio-operator
# Pin to a known-good release; matches CRC 4.22 Kubernetes API level.
MINIO_OPERATOR_VER=v6.0.4
oc apply -k "github.com/minio/operator/resources/?ref=${MINIO_OPERATOR_VER}" 2>/dev/null \
  || oc apply -f "https://raw.githubusercontent.com/minio/operator/${MINIO_OPERATOR_VER}/resources/base/operator.yaml"

echo "==> Waiting for the MinIO operator to be Ready"
for i in $(seq 1 60); do
  ready=$(oc -n minio-operator get deploy minio-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${ready:-0}" -ge 1 ] && { echo "  minio-operator Ready"; break; }
  sleep 5
done

cat <<EOF

Done. To provision a MinIO tenant in a project (example):

  oc new-project object-storage 2>/dev/null || true
  cat <<TENANT | oc -n object-storage apply -f -
  apiVersion: minio.min.io/v2
  kind: Tenant
  metadata: {name: hcloud}
  spec:
    image: quay.io/minio/minio:latest
    pools:
      - servers: 1
        volumesPerServer: 4
        name: pool-0
        volumeClaimTemplate:
          metadata: {name: data}
          spec:
            accessModes: [ReadWriteOnce]
            resources: {requests: {storage: 100Gi}}
            storageClassName: ocs-external-storagecluster-ceph-rbd
  TENANT

Then expose the tenant's S3 endpoint via an OpenShift Route.
EOF
