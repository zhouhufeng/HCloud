#!/usr/bin/env bash
# HCloud middleware · 14 — tenants (NERC-style projects + quotas).
#
# For each name in HCLOUD_USERS: a namespace, a ResourceQuota, a LimitRange, an
# admin ServiceAccount, and a ready-to-use kubeconfig written to
# docs/Secretes/users/<user>.kubeconfig (git-ignored). Pure Kubernetes — no
# OpenShift OAuth, no htpasswd — so it is the same on every platform. Federated
# login (Keycloak/CILogon, as NERC had) is a later add-on once a public URL exists.
# Idempotent; re-running rotates the token.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env; hc_setup_kubectl
[ -n "$HCLOUD_USERS" ] || hc_die "HCLOUD_USERS is empty (space-separated user names)"

: "${HCLOUD_Q_CPU_REQ:=4}" "${HCLOUD_Q_MEM_REQ:=16Gi}" "${HCLOUD_Q_CPU_LIM:=8}"
: "${HCLOUD_Q_MEM_LIM:=32Gi}" "${HCLOUD_Q_PVC_CT:=20}" "${HCLOUD_Q_PVC_SZ:=500Gi}"

OUT="$HCLOUD_SECRETS/users"; mkdir -p "$OUT"; chmod 700 "$OUT"
SERVER="${HCLOUD_API_URL:-$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')}"
CA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

for u in $HCLOUD_USERS; do
  hc_log "Tenant '$u'"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata: {name: ${u}, labels: {hcloud.io/tenant: "${u}"}}
---
apiVersion: v1
kind: ResourceQuota
metadata: {name: default, namespace: ${u}}
spec:
  hard:
    requests.cpu: "${HCLOUD_Q_CPU_REQ}"
    requests.memory: "${HCLOUD_Q_MEM_REQ}"
    limits.cpu: "${HCLOUD_Q_CPU_LIM}"
    limits.memory: "${HCLOUD_Q_MEM_LIM}"
    persistentvolumeclaims: "${HCLOUD_Q_PVC_CT}"
    requests.storage: "${HCLOUD_Q_PVC_SZ}"
---
apiVersion: v1
kind: LimitRange
metadata: {name: default, namespace: ${u}}
spec:
  limits:
    - type: Container
      default:        {cpu: 500m, memory: 1Gi}
      defaultRequest: {cpu: 100m, memory: 128Mi}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: ${u}-admin, namespace: ${u}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ${u}-admin, namespace: ${u}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}
subjects: [{kind: ServiceAccount, name: ${u}-admin, namespace: ${u}}]
EOF
  TOKEN="$(kubectl -n "$u" create token "${u}-admin" --duration="${HCLOUD_TOKEN_TTL:-8760h}")"
  umask 077
  cat > "$OUT/$u.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: hcloud
    cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}
users:
  - name: ${u}
    user: {token: ${TOKEN}}
contexts:
  - name: hcloud
    context: {cluster: hcloud, user: ${u}, namespace: ${u}}
current-context: hcloud
EOF
  echo "   kubeconfig → $OUT/$u.kubeconfig"
done

echo
echo "Done. Hand each user their kubeconfig: KUBECONFIG=<file> kubectl get pods"
echo "Next: hcloud/15-monitoring.sh"
