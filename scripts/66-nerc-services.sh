#!/usr/bin/env bash
# Phase 6.6 (Mac Studio target): NERC-parity operator install.
# Installs, in one pass:
#   - OpenDataHub (RHOAI upstream: JupyterLab workbenches, KServe model serving)
#   - OpenShift Serverless    (Knative: NERC 'Serverless Computing')
#   - OpenShift Pipelines     (Tekton:  NERC 'CI/CD Pipeline')
#
# Notes/honest gaps vs NERC:
#   - GPU-backed workloads: not viable on Apple Silicon (Metal is not exposed
#     to Linux containers via vfkit). RHOAI dashboards + CPU-only notebooks
#     still work; skip GPU workbench profiles.
#   - RHOAI (Red Hat's distribution) is subscription-gated; OpenDataHub is the
#     same operator upstream and enables the same features on OKD/CRC.
set -euo pipefail

if [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null; then eval "$(crc oc-env)"; fi
command -v oc >/dev/null || { echo "ERROR: oc missing"; exit 1; }

wait_csv () {
  ns="$1"; needle="$2"; label="$3"
  echo "==> Waiting for $label CSV to Succeeded"
  for i in $(seq 1 90); do
    if oc -n "$ns" get csv 2>/dev/null | grep -E "$needle" | grep -q Succeeded; then
      echo "  $label ready"; return 0
    fi
    sleep 10
  done
  echo "  WARNING: $label CSV not Succeeded after 15 min; continuing"
}

echo "==> OpenShift Pipelines (Tekton) — CI/CD Pipeline parity"
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
wait_csv openshift-operators "openshift-pipelines-operator" "OpenShift Pipelines"

echo "==> OpenShift Serverless (Knative) — Serverless Computing parity"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
wait_csv openshift-serverless "serverless-operator" "OpenShift Serverless"

echo "==> Enabling Knative Serving"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: knative-serving
---
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec: {}
EOF

echo "==> JupyterHub (NERC RHOAI/JupyterLab parity)"
# Found on this Mac (2026-07-29): the OpenDataHub operator is NOT in the
# community-operators catalog on aarch64 — ODH images are x86_64-only, so the
# catalog filters the package out on Apple Silicon ("no operators found in
# package opendatahub-operator"). JupyterHub (zero-to-jupyterhub chart) is
# multi-arch and provides the JupyterLab-workbench experience NERC users had.
command -v helm >/dev/null || { echo "ERROR: helm missing"; exit 1; }
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null 2>&1 || true
helm repo update jupyterhub >/dev/null
oc get ns jupyterhub >/dev/null 2>&1 || oc create ns jupyterhub
# The chart pins runAsUser 1000/65534 + fsGroup 1000, which OpenShift's
# restricted-v2 SCC rejects; anyuid for this namespace's SAs is the fix.
oc adm policy add-scc-to-group anyuid system:serviceaccounts:jupyterhub
helm upgrade --install jupyterhub jupyterhub/jupyterhub -n jupyterhub \
  --set prePuller.hook.enabled=false --set prePuller.continuous.enabled=false \
  --set proxy.service.type=ClusterIP \
  --set hub.db.pvc.storageClassName=ocs-external-storagecluster-ceph-rbd \
  --set singleuser.storage.dynamic.storageClass=ocs-external-storagecluster-ceph-rbd \
  --set singleuser.storage.capacity=10Gi \
  --set singleuser.memory.limit=4G --set singleuser.memory.guarantee=1G \
  --set singleuser.cpu.limit=2 --set singleuser.cpu.guarantee=0.1 \
  --set cull.enabled=true --set cull.timeout=3600 \
  --timeout 10m
oc -n jupyterhub create route edge jupyterhub --service=proxy-public --insecure-policy=Redirect 2>/dev/null || true

cat <<'EOF'

Done. NERC-parity services installed. Give the pods ~5 min to settle, then:
  - Pipelines : oc get tektonconfig
  - Serverless: oc -n knative-serving get pods
  - JupyterHub: oc -n jupyterhub get route jupyterhub   (the notebook UI)
Notes:
  - OpenDataHub/RHOAI operator unavailable on Apple Silicon (x86_64-only) —
    JupyterHub stands in for JupyterLab workbenches.
  - GPU workbench profiles are not possible on this box (no NVIDIA GPU).
EOF
