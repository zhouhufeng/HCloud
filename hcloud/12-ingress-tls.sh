#!/usr/bin/env bash
# HCloud middleware · 12 — ingress + TLS.
#
# Installs the one ingress every platform gets: ingress-nginx (IngressClass
# "nginx", default; SSL passthrough enabled because some NERC Routes need it).
# If HCLOUD_DOMAIN is set, also installs cert-manager with a Let's Encrypt
# ClusterIssuer (Cloudflare DNS-01) and a wildcard certificate for *.HCLOUD_DOMAIN
# that becomes ingress-nginx's default certificate — so application Ingresses
# need no per-host TLS blocks.
#
# Needs (only when HCLOUD_DOMAIN is set): HCLOUD_ACME_EMAIL and a Cloudflare API
# token with Zone.DNS:Edit — HCLOUD_CF_API_TOKEN or docs/Secretes/cloudflare-api-token.txt.
# Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env; hc_setup_kubectl; hc_ensure_helm

hc_log "ingress-nginx (service type: $HCLOUD_INGRESS_SVC_TYPE)"
hc_helm_repo ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.ingressClassResource.default=true \
  --set controller.service.type="$HCLOUD_INGRESS_SVC_TYPE" \
  --set controller.extraArgs.enable-ssl-passthrough=true \
  --set controller.extraArgs.default-ssl-certificate=ingress-nginx/hcloud-wildcard-tls \
  --wait --timeout 5m
# (the default-ssl-certificate secret may not exist yet; nginx falls back to its
#  self-signed cert and picks the real one up as soon as cert-manager issues it)

if [ -z "$HCLOUD_DOMAIN" ]; then
  echo; echo "HCLOUD_DOMAIN empty → LAN-only cluster; skipping cert-manager. Done."; exit 0
fi

[ -n "$HCLOUD_ACME_EMAIL" ] || hc_die "HCLOUD_ACME_EMAIL required with HCLOUD_DOMAIN"
CF_TOKEN="$(hc_secret HCLOUD_CF_API_TOKEN cloudflare-api-token.txt)" \
  || hc_die "Cloudflare token: set HCLOUD_CF_API_TOKEN or create $HCLOUD_SECRETS/cloudflare-api-token.txt"

hc_log "cert-manager"
hc_helm_repo jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m
hc_wait_deploy cert-manager cert-manager-webhook 180s

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CF_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

hc_log "ClusterIssuer letsencrypt-prod (DNS-01 via Cloudflare)"
kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: letsencrypt-prod}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${HCLOUD_ACME_EMAIL}
    privateKeySecretRef: {name: letsencrypt-prod-account-key}
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef: {name: cloudflare-api-token, key: api-token}
EOF

hc_log "Wildcard certificate *.${HCLOUD_DOMAIN} → ingress-nginx/hcloud-wildcard-tls"
kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: hcloud-wildcard, namespace: ingress-nginx}
spec:
  secretName: hcloud-wildcard-tls
  issuerRef: {name: letsencrypt-prod, kind: ClusterIssuer}
  commonName: "*.${HCLOUD_DOMAIN}"
  dnsNames: ["*.${HCLOUD_DOMAIN}", "${HCLOUD_DOMAIN}"]
EOF

hc_log "Waiting for issuance (DNS propagation, 2–5 min)"
for i in $(seq 1 60); do
  st=$(kubectl -n ingress-nginx get certificate hcloud-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$st" = True ] && { echo "  certificate Ready"; break; }
  sleep 10
done
[ "$st" = True ] || hc_warn "certificate not Ready yet — check: kubectl -n ingress-nginx describe certificate hcloud-wildcard"

echo
echo "Done. Any Ingress with host <name>.${HCLOUD_DOMAIN} is served with a real certificate."
echo "Next: hcloud/13-public-tunnel.sh (public reachability without a static IP)"
