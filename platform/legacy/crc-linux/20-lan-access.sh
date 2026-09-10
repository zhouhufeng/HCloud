#!/usr/bin/env bash
# Phase 2: expose the CRC cluster to other machines on the LAN via HAProxy on the host.
# CRC binds to a host-only network; this forwards 80/443/6443 from the workstation's LAN IP.
# Colleagues then reach apps at https://<name>.apps.<LAN_IP>.nip.io and the API at :6443.
set -euo pipefail

CRC_IP=$(crc ip)
LAN_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
echo "CRC VM IP: $CRC_IP   LAN IP: $LAN_IP"

sudo apt-get install -y haproxy

sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<EOF
global
    log /dev/log local0
defaults
    mode tcp
    log global
    timeout connect 10s
    timeout client 300s
    timeout server 300s

frontend apps_http
    bind ${LAN_IP}:80
    default_backend crc_http
backend crc_http
    server crc ${CRC_IP}:80

frontend apps_https
    bind ${LAN_IP}:443
    default_backend crc_https
backend crc_https
    server crc ${CRC_IP}:443

frontend api
    bind ${LAN_IP}:6443
    default_backend crc_api
backend crc_api
    server crc ${CRC_IP}:6443
EOF

sudo systemctl restart haproxy
echo "Done. From another machine on the LAN:"
echo "  oc login https://${LAN_IP}:6443  (cert warnings expected; or add DNS entries for api.crc.testing -> ${LAN_IP})"
echo "  Apps: expose routes with host <name>.apps.${LAN_IP}.nip.io"
