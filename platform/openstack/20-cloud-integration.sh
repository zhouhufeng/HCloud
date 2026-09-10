#!/usr/bin/env bash
# Platform: OpenStack · 20 — cloud integration add-on (run AFTER the middleware, from a server).
#
# Installs the OpenStack cloud-controller-manager and Cinder CSI so the cluster can use
# Cinder volumes and (later) Octavia load balancers, adds StorageClass `cinder-ceph` for
# replicated general-purpose PVs, and re-points the NERC alias StorageClass at it. The
# node-pinned `local-path` class stays for the databases (docs/platforms/openstack.md §6, §14).
#
# Needs: a cloud.conf (application credential) at docs/Secretes/openstack-cloud.conf, and
# every node installed with HCLOUD_K8S_EXTRA_ARGS containing "--kubelet-arg cloud-provider=external".
set -euo pipefail
. "$(dirname "$0")/../../hcloud/lib.sh"; hc_load_env; hc_setup_kubectl; hc_ensure_helm
CONF="$HCLOUD_SECRETS/openstack-cloud.conf"
[ -f "$CONF" ] || hc_die "$CONF missing — see docs/platforms/openstack.md §14.1 for its contents"

hc_log "cloud.conf secret"
kubectl -n kube-system create secret generic cloud-config --from-file=cloud.conf="$CONF" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

hc_log "OpenStack cloud-controller-manager + Cinder CSI"
hc_helm_repo cpo https://kubernetes.github.io/cloud-provider-openstack
helm upgrade --install ccm cpo/openstack-cloud-controller-manager -n kube-system \
  --set secret.enabled=false --set secret.name=cloud-config --wait --timeout 5m
helm upgrade --install cinder-csi cpo/openstack-cinder-csi -n kube-system \
  --set secret.enabled=false --set secret.name=cloud-config --wait --timeout 5m

hc_log "Provider IDs (must read openstack://…)"
kubectl get nodes -o custom-columns=NODE:.metadata.name,PROVIDER:.spec.providerID

hc_log "StorageClass cinder-ceph; NERC alias → cinder-ceph"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: cinder-ceph}
provisioner: cinder.csi.openstack.org
parameters: {type: __DEFAULT__}
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl delete storageclass ocs-external-storagecluster-ceph-rbd --ignore-not-found >/dev/null
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-external-storagecluster-ceph-rbd
  annotations: {hcloud.io/notes: "NERC class name → Cinder (replicated), set by platform/openstack/20-cloud-integration.sh"}
provisioner: cinder.csi.openstack.org
parameters: {type: __DEFAULT__}
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl get storageclass
echo; echo "Done. Databases keep local-path (host NVMe); everything replicated goes to cinder-ceph."
