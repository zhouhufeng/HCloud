#!/usr/bin/env bash
# HCloud middleware · 13 — public serving via Cloudflare Tunnel, in-cluster.
#
# cloudflared runs as a Deployment inside the cluster and forwards
# *.HCLOUD_DOMAIN to the ingress-nginx Service. Because it is a pod, it is
# identical on every platform and needs no inbound port, static IP, or
# port-forward on the host — which is the point of the middleware.
#
# One-time on the OPERATOR machine (where you run this script):
#   cloudflared tunnel login       # browser → ~/.cloudflared/cert.pem (zone must be on Cloudflare)
# Needs: HCLOUD_DOMAIN, HCLOUD_TUNNEL_NAME; jq.
#   HCLOUD_TUNNEL_EXPOSE_API=true  also publishes the Kubernetes API at api.HCLOUD_DOMAIN
# Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"; hc_load_env; hc_setup_kubectl
[ -n "$HCLOUD_DOMAIN" ] || hc_die "HCLOUD_DOMAIN is empty — nothing to publish"
hc_require jq

if ! command -v cloudflared >/dev/null 2>&1; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  url=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 ;;
    Linux-aarch64) url=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 ;;
    *) hc_die "install cloudflared for this OS first (brew install cloudflared)";;
  esac
  hc_log "Installing cloudflared CLI"; sudo curl -fsSL -o /usr/local/bin/cloudflared "$url"; sudo chmod +x /usr/local/bin/cloudflared
fi
[ -f "$HOME/.cloudflared/cert.pem" ] || hc_die "~/.cloudflared/cert.pem missing — run: cloudflared tunnel login"

# ---- tunnel + DNS (Cloudflare side) --------------------------------------
TUNNEL_ID="$(cloudflared tunnel list --output json | jq -r --arg n "$HCLOUD_TUNNEL_NAME" '.[] | select(.name==$n) | .id' | head -1)"
if [ -z "$TUNNEL_ID" ]; then
  hc_log "Creating tunnel $HCLOUD_TUNNEL_NAME"
  cloudflared tunnel create "$HCLOUD_TUNNEL_NAME" >/dev/null
  TUNNEL_ID="$(cloudflared tunnel list --output json | jq -r --arg n "$HCLOUD_TUNNEL_NAME" '.[] | select(.name==$n) | .id' | head -1)"
fi
CRED="$HOME/.cloudflared/${TUNNEL_ID}.json"
[ -f "$CRED" ] || hc_die "credentials $CRED not found (tunnel created on another machine? copy the file)"
cp "$CRED" "$HCLOUD_SECRETS/cloudflared-${HCLOUD_TUNNEL_NAME}.json" 2>/dev/null || true
hc_log "Tunnel $HCLOUD_TUNNEL_NAME = $TUNNEL_ID"

hc_log "DNS: ${HCLOUD_DOMAIN}, *.${HCLOUD_DOMAIN} → tunnel (idempotent)"
for h in "$HCLOUD_DOMAIN" "*.${HCLOUD_DOMAIN}"; do
  cloudflared tunnel route dns --overwrite-dns "$HCLOUD_TUNNEL_NAME" "$h" 2>&1 | tail -1 || true
done

# ---- in-cluster connector ---------------------------------------------------
hc_ensure_ns cloudflared
kubectl -n cloudflared create secret generic tunnel-credentials \
  --from-file=credentials.json="$CRED" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

API_RULE=""
if [ "${HCLOUD_TUNNEL_EXPOSE_API:-false}" = true ]; then
  cloudflared tunnel route dns --overwrite-dns "$HCLOUD_TUNNEL_NAME" "api.${HCLOUD_DOMAIN}" 2>&1 | tail -1 || true
  API_RULE="      - hostname: api.${HCLOUD_DOMAIN}
        service: https://kubernetes.default.svc.cluster.local:443
        originRequest: {noTLSVerify: true}"
fi

kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata: {name: cloudflared, namespace: cloudflared}
data:
  config.yaml: |
    tunnel: ${TUNNEL_ID}
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
    # Host header is preserved, so ingress-nginx routes by the Ingress host.
    # Origin TLS is the in-cluster hop; the real certificate is what clients see at the edge.
    ingress:
${API_RULE}
      - hostname: "*.${HCLOUD_DOMAIN}"
        service: https://ingress-nginx-controller.ingress-nginx.svc.cluster.local:443
        originRequest: {noTLSVerify: true}
      - hostname: "${HCLOUD_DOMAIN}"
        service: https://ingress-nginx-controller.ingress-nginx.svc.cluster.local:443
        originRequest: {noTLSVerify: true}
      - service: http_status:404
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: cloudflared, namespace: cloudflared}
spec:
  replicas: 2
  selector: {matchLabels: {app: cloudflared}}
  template:
    metadata: {labels: {app: cloudflared}}
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args: ["tunnel", "--config", "/etc/cloudflared/config/config.yaml", "run"]
          livenessProbe: {httpGet: {path: /ready, port: 2000}, initialDelaySeconds: 10, periodSeconds: 10}
          volumeMounts:
            - {name: config, mountPath: /etc/cloudflared/config, readOnly: true}
            - {name: creds,  mountPath: /etc/cloudflared/creds,  readOnly: true}
      volumes:
        - name: config
          configMap: {name: cloudflared}
        - name: creds
          secret: {secretName: tunnel-credentials}
EOF
kubectl -n cloudflared rollout restart deploy/cloudflared >/dev/null
hc_wait_deploy cloudflared cloudflared 180s

cat <<EOF

Done. Verify in ~30 s:
  cloudflared tunnel info ${HCLOUD_TUNNEL_NAME}
  curl -I https://<any-ingress-host>.${HCLOUD_DOMAIN}/
Every Ingress with host <name>.${HCLOUD_DOMAIN} is now public. Next: hcloud/14-tenants.sh
EOF
