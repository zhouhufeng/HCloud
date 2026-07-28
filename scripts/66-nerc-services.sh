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

echo "==> OpenDataHub (RHOAI upstream) — JupyterLab / KServe / Model Serving parity"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: opendatahub
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: opendatahub
  namespace: opendatahub
spec:
  targetNamespaces:
    - opendatahub
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opendatahub-operator
  namespace: opendatahub
spec:
  channel: fast
  name: opendatahub-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
wait_csv opendatahub "opendatahub-operator" "OpenDataHub"

echo "==> Creating DataScienceCluster"
cat <<'EOF' | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:            {managementState: Managed}
    workbenches:          {managementState: Managed}
    datasciencepipelines: {managementState: Managed}
    kserve:               {managementState: Managed, serving: {managementState: Managed, name: knative-serving}}
    modelmeshserving:     {managementState: Managed}
    codeflare:            {managementState: Removed}
    ray:                  {managementState: Removed}
    kueue:                {managementState: Removed}
    trainingoperator:     {managementState: Removed}
    trustyai:             {managementState: Removed}
EOF

cat <<'EOF'

Done. NERC-parity operators installed. Give the pods ~5 min to settle, then:
  - Pipelines : oc get tektonconfig
  - Serverless: oc -n knative-serving get pods
  - RHOAI/ODH : oc get route -n opendatahub          (the dashboard route)
GPU workbench profiles are intentionally disabled on this box (no NVIDIA GPU).
EOF
