#!/usr/bin/env bash
# Phase 4 (production pivot): install RKE2 bare-metal on this host to replace CRC.
# Places PVC data on the 22TB HSA disk via Rancher local-path-provisioner.
# Requires sudo. Idempotent-ish. Run after a reboot that has stopped the CRC VM.
set -euo pipefail

STORAGE_DIR="${HCLOUD_STORAGE_DIR:-/media/hzhou/HSA/rke2-storage}"
TLS_SAN="${HCLOUD_TLS_SAN:-}"   # optional: your public domain, e.g. genohub.org

echo "==> Pre-flight"
[ -d /media/hzhou/HSA ] || { echo "ERROR: HSA disk not mounted at /media/hzhou/HSA"; exit 1; }
command -v curl >/dev/null || sudo apt-get install -y curl

echo "==> Retiring CRC (free its resources; ignore errors if already down)"
if command -v crc >/dev/null; then crc stop 2>/dev/null || true; fi
# leave the crc binary + libvirt stack in place; just ensure the VM isn't running
sudo virsh -c qemu:///system destroy crc 2>/dev/null || true

echo "==> Installing RKE2 server"
if [ ! -x /usr/local/bin/rke2 ] && [ ! -x /var/lib/rancher/rke2/bin/rke2 ]; then
  curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=server sh -
fi

echo "==> Writing /etc/rancher/rke2/config.yaml"
sudo mkdir -p /etc/rancher/rke2
{
  echo "write-kubeconfig-mode: \"0644\""
  echo "# ingress-nginx ships by default; keep it for public serving"
  if [ -n "$TLS_SAN" ]; then
    echo "tls-san:"
    echo "  - $TLS_SAN"
  fi
} | sudo tee /etc/rancher/rke2/config.yaml >/dev/null

echo "==> Enabling + starting rke2-server (first start pulls images, ~3-6 min)"
sudo systemctl enable --now rke2-server.service

echo "==> Waiting for node Ready"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
BIN=/var/lib/rancher/rke2/bin
export PATH="$BIN:$PATH"
for i in $(seq 1 60); do
  if "$BIN/kubectl" get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
  sleep 5
done
"$BIN/kubectl" get nodes

echo "==> Installing Rancher local-path-provisioner backed by $STORAGE_DIR"
sudo mkdir -p "$STORAGE_DIR"
"$BIN/kubectl" apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
# repoint the provisioner at the HSA disk and make it the default StorageClass
"$BIN/kubectl" -n local-path-storage patch configmap local-path-config --type merge \
  -p "{\"data\":{\"config.json\":\"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"$STORAGE_DIR\\\"]}]}\"}}"
"$BIN/kubectl" -n local-path-storage rollout restart deploy/local-path-provisioner
"$BIN/kubectl" patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

cat <<EOF

Done. RKE2 is up and 'local-path' (on $STORAGE_DIR) is the default StorageClass.
  kubeconfig : /etc/rancher/rke2/rke2.yaml  (KUBECONFIG env or copy to ~/.kube/config)
  kubectl    : $BIN/kubectl
Next: scripts to convert + apply the favor-4ee4be manifests, then migrate PVC data.
EOF
