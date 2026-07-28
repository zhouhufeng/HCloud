#!/usr/bin/env bash
# Phase 6.2 (Mac Studio target): expose CRC apps publicly via Cloudflare Tunnel.
#
# Cloudflared runs as a launchd service on the macOS host; the tunnel forwards
# HTTPS to the CRC router (host-only vmnet network) with the OpenShift Route
# host preserved. Public TLS is terminated at Cloudflare's edge. The origin leg
# uses CRC's self-signed router cert with noTLSVerify — safe: the traffic is on
# a private virtual-network segment inside this Mac.
#
# One-time manual steps you MUST do first:
#   1. Own a public domain on Cloudflare (e.g. hcloud.example.edu).
#   2. cloudflared tunnel login         (opens browser; drops ~/.cloudflared/cert.pem)
#   3. export HCLOUD_TUNNEL_NAME=hcloud-mac
#      export HCLOUD_DOMAIN=hcloud.example.edu
#      bash scripts/62-cloudflared-tunnel.sh
set -euo pipefail

: "${HCLOUD_TUNNEL_NAME:?set HCLOUD_TUNNEL_NAME (e.g. hcloud-mac)}"
: "${HCLOUD_DOMAIN:?set HCLOUD_DOMAIN (e.g. hcloud.example.edu)}"

command -v cloudflared >/dev/null || { echo "ERROR: cloudflared missing"; exit 1; }
command -v crc         >/dev/null || { echo "ERROR: crc missing"; exit 1; }
[ -f "$HOME/.cloudflared/cert.pem" ] || {
  echo "ERROR: ~/.cloudflared/cert.pem missing. Run 'cloudflared tunnel login' first."; exit 1
}

CRC_IP=$(crc ip)
[ -n "$CRC_IP" ] || { echo "ERROR: 'crc ip' returned empty — is the cluster running?"; exit 1; }
echo "==> CRC router at ${CRC_IP}, exposing domain ${HCLOUD_DOMAIN} via tunnel ${HCLOUD_TUNNEL_NAME}"

# Create tunnel if absent (idempotent)
if ! cloudflared tunnel list 2>/dev/null | awk 'NR>2 {print $2}' | grep -qx "$HCLOUD_TUNNEL_NAME"; then
  echo "==> Creating tunnel ${HCLOUD_TUNNEL_NAME}"
  cloudflared tunnel create "$HCLOUD_TUNNEL_NAME"
else
  echo "==> Tunnel ${HCLOUD_TUNNEL_NAME} exists"
fi
TUNNEL_ID=$(cloudflared tunnel list | awk -v n="$HCLOUD_TUNNEL_NAME" 'NR>2 && $2==n {print $1}')
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
[ -f "$CRED_FILE" ] || { echo "ERROR: tunnel credentials file $CRED_FILE not found"; exit 1; }

echo "==> Writing ~/.cloudflared/config.yml"
cat > "$HOME/.cloudflared/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

# Wildcard *.${HCLOUD_DOMAIN}  -> CRC OpenShift router (Routes preserved by Host header)
# api.${HCLOUD_DOMAIN}         -> CRC kube API on 6443
# Everything else              -> 404
ingress:
  - hostname: api.${HCLOUD_DOMAIN}
    service: https://${CRC_IP}:6443
    originRequest:
      noTLSVerify: true
  - hostname: "*.${HCLOUD_DOMAIN}"
    service: https://${CRC_IP}:443
    originRequest:
      noTLSVerify: true
  - hostname: ${HCLOUD_DOMAIN}
    service: https://${CRC_IP}:443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

echo "==> Adding Cloudflare DNS routes (idempotent; may say 'already exists')"
cloudflared tunnel route dns "$HCLOUD_TUNNEL_NAME" "${HCLOUD_DOMAIN}"     2>&1 | tail -1 || true
cloudflared tunnel route dns "$HCLOUD_TUNNEL_NAME" "*.${HCLOUD_DOMAIN}"   2>&1 | tail -1 || true
cloudflared tunnel route dns "$HCLOUD_TUNNEL_NAME" "api.${HCLOUD_DOMAIN}" 2>&1 | tail -1 || true

echo "==> Installing/starting cloudflared as a launchd service"
sudo cloudflared service install 2>&1 | tail -3 || true
sudo launchctl kickstart -k system/com.cloudflare.cloudflared 2>/dev/null || true

cat <<EOF

Done. Verify in ~30 s:
  cloudflared tunnel info ${HCLOUD_TUNNEL_NAME}
  curl -kI https://api.${HCLOUD_DOMAIN}/healthz
  curl -kI https://console.${HCLOUD_DOMAIN}/     (once you re-host the console route)

For any Route you migrate to this cluster, set:
  spec.host: <appname>.${HCLOUD_DOMAIN}
and it will resolve publicly. Wildcard *.${HCLOUD_DOMAIN} is already routed.
EOF
