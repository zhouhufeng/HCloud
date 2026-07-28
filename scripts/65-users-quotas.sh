#!/usr/bin/env bash
# Phase 6.5 (Mac Studio target): NERC-style users + per-project quotas.
#
# NERC uses MSS Keycloak + CILogon federated login backed by ColdFront quotas.
# Here we start with the pragmatic equivalent — a local htpasswd IdP + explicit
# ResourceQuotas — because Keycloak+CILogon needs an internet-reachable OIDC
# callback that this cluster gets only after 62-cloudflared-tunnel.sh is up.
# Once the public URL exists, swap the IdP with an OpenID Connect entry.
#
# Users default to whatever's in HCLOUD_USERS (space-separated). Passwords are
# generated + saved under the git-ignored docs/Secretes/users/passwords.txt.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USERS="${HCLOUD_USERS:-hzhou}"

# NERC-style quota defaults (mirroring their pilot allocation feel)
Q_CPU_REQ="${HCLOUD_Q_CPU_REQ:-4}"
Q_MEM_REQ="${HCLOUD_Q_MEM_REQ:-16Gi}"
Q_CPU_LIM="${HCLOUD_Q_CPU_LIM:-8}"
Q_MEM_LIM="${HCLOUD_Q_MEM_LIM:-32Gi}"
Q_PVC_CT="${HCLOUD_Q_PVC_CT:-20}"
Q_PVC_SZ="${HCLOUD_Q_PVC_SZ:-500Gi}"

if [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null; then eval "$(crc oc-env)"; fi
command -v oc >/dev/null || { echo "ERROR: oc missing"; exit 1; }
command -v htpasswd >/dev/null || { echo "==> Installing httpd for htpasswd"; brew install httpd; }

SECRET_DIR="$REPO_ROOT/docs/Secretes/users"
mkdir -p "$SECRET_DIR"
HTPASSWD="$SECRET_DIR/htpasswd"
PWFILE="$SECRET_DIR/passwords.txt"
: > "$HTPASSWD"
touch "$PWFILE"; chmod 600 "$PWFILE"

echo "==> Provisioning users: $USERS"
for u in $USERS; do
  pw=$(openssl rand -base64 15 | tr -d '/+=')
  htpasswd -B -b "$HTPASSWD" "$u" "$pw"
  echo "$u:$pw" >> "$PWFILE"
done

oc -n openshift-config create secret generic hcloud-htpasswd \
  --from-file=htpasswd="$HTPASSWD" --dry-run=client -o yaml | oc apply -f -

echo "==> Setting HTPasswd identity provider"
cat <<'EOF' | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
    - name: hcloud
      mappingMethod: claim
      type: HTPasswd
      htpasswd:
        fileData:
          name: hcloud-htpasswd
EOF

for u in $USERS; do
  echo "==> Project '$u' + quota"
  oc adm new-project "$u" --description="HCloud project for $u" --display-name="$u" 2>/dev/null || true
  oc adm policy add-role-to-user admin "$u" -n "$u"
  cat <<EOF | oc apply -n "$u" -f -
apiVersion: v1
kind: ResourceQuota
metadata: {name: default}
spec:
  hard:
    requests.cpu:              "${Q_CPU_REQ}"
    requests.memory:           "${Q_MEM_REQ}"
    limits.cpu:                "${Q_CPU_LIM}"
    limits.memory:             "${Q_MEM_LIM}"
    persistentvolumeclaims:    "${Q_PVC_CT}"
    requests.storage:          "${Q_PVC_SZ}"
---
apiVersion: v1
kind: LimitRange
metadata: {name: default}
spec:
  limits:
    - type: Container
      default:        {cpu: 500m,  memory: 1Gi}
      defaultRequest: {cpu: 100m,  memory: 128Mi}
EOF
done

echo
echo "Users + quotas set. Credentials in $PWFILE (git-ignored)."
echo "Login: 'hcloud' identity provider on the console (after ~30s for the OAuth pod to redeploy)."
