#!/usr/bin/env bash
# Phase 6.3 (Mac Studio target): install cert-manager + a Let's Encrypt
# ClusterIssuer that uses Cloudflare DNS-01. Real TLS for cluster Routes; also
# gives you an origin cert so Cloudflare "Full (strict)" mode is possible.
#
# Manual: create a Cloudflare API token scoped to Zone.DNS:Edit for your zone,
# then export:
#   export HCLOUD_CF_API_TOKEN=xxxxxxxx
#   export HCLOUD_ACME_EMAIL=you@example.edu
#   export HCLOUD_DOMAIN=hcloud.example.edu       # same as script 62
set -euo pipefail

: "${HCLOUD_CF_API_TOKEN:?set HCLOUD_CF_API_TOKEN (Cloudflare token with Zone.DNS:Edit)}"
: "${HCLOUD_ACME_EMAIL:?set HCLOUD_ACME_EMAIL}"
: "${HCLOUD_DOMAIN:?set HCLOUD_DOMAIN (e.g. hcloud.example.edu)}"

if [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null; then eval "$(crc oc-env)"; fi
command -v oc   >/dev/null || { echo "ERROR: oc missing"; exit 1; }
command -v helm >/dev/null || { echo "ERROR: helm missing"; exit 1; }

echo "==> Adding jetstack Helm repo"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

echo "==> Installing cert-manager (CRDs + controller + webhook + cainjector)"
oc get ns cert-manager >/dev/null 2>&1 || oc create ns cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true \
  --wait --timeout 5m

echo "==> Waiting for the webhook to accept requests"
oc -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

echo "==> Storing Cloudflare API token"
oc -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$HCLOUD_CF_API_TOKEN" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> ClusterIssuer letsencrypt-prod (DNS-01 via Cloudflare)"
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${HCLOUD_ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

echo "==> Requesting a wildcard cert for *.${HCLOUD_DOMAIN}"
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hcloud-wildcard
  namespace: openshift-ingress
spec:
  secretName: hcloud-wildcard-tls
  issuerRef: {name: letsencrypt-prod, kind: ClusterIssuer}
  commonName: "*.${HCLOUD_DOMAIN}"
  dnsNames:
    - "*.${HCLOUD_DOMAIN}"
    - "${HCLOUD_DOMAIN}"
EOF

echo "==> Waiting for issuance (2-5 min while DNS propagates)"
for i in $(seq 1 60); do
  state=$(oc -n openshift-ingress get certificate hcloud-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$state" = "True" ] && { echo "  cert Ready"; break; }
  sleep 10
done

echo "==> Setting the cert as the default router certificate"
oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
  -p '{"spec":{"defaultCertificate":{"name":"hcloud-wildcard-tls"}}}'

echo
echo "Done. Any Route with host <name>.${HCLOUD_DOMAIN} is now served with a real LE cert."
echo "In Cloudflare, you can now safely switch SSL/TLS mode to 'Full (strict)'."
