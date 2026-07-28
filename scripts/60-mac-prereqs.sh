#!/usr/bin/env bash
# Phase 6.0 (Mac Studio target): install the tooling CRC + public serving need on macOS.
#
# Target machine: Apple Silicon Mac (M-series Ultra), 128 GiB RAM. This box is
# the *primary* HCloud production replacement for NERC (the Linux boxes in
# scripts/00-01 remain as pilot/dev). Idempotent; safe to re-run.
#
# What it does:
#   1. Verifies Apple Silicon + macOS + adequate RAM.
#   2. Installs Homebrew if missing (asks for confirmation; needs sudo once).
#   3. Installs: crc, cloudflared, helm, kubectl, openshift-cli, jq.
#   4. Reminds you to save your Red Hat pull secret before running 61-*.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Verifying host"
[ "$(uname)" = "Darwin" ]      || { echo "ERROR: not macOS"; exit 1; }
[ "$(uname -m)" = "arm64" ]    || { echo "ERROR: this script targets Apple Silicon (arm64); found $(uname -m)"; exit 1; }
ram_gib=$(sysctl -n hw.memsize | awk '{printf "%d", $1/1073741824}')
[ "$ram_gib" -ge 96 ]          || { echo "ERROR: need >=96 GiB RAM for the mac-studio profile; found ${ram_gib} GiB"; exit 1; }
echo "  macOS $(sw_vers -productVersion) on $(sysctl -n machdep.cpu.brand_string), ${ram_gib} GiB"

if ! command -v brew >/dev/null 2>&1; then
  echo "==> Installing Homebrew (you'll be prompted for your password once)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Put brew on PATH for this shell (Apple Silicon default prefix)
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  echo "==> Homebrew already installed"
fi
brew --version | head -1

echo "==> Installing CLI tools (crc, cloudflared, helm, kubectl, openshift-cli, jq)"
# crc ships as a cask on Apple Silicon; the rest are formulae.
brew install --quiet helm kubectl openshift-cli jq cloudflared || true
brew install --cask --quiet crc || true

echo "==> Verifying tool versions"
crc version         | head -1
cloudflared --version
helm version --short
kubectl version --client --output=yaml 2>/dev/null | head -3 || kubectl version --client
oc  version --client
jq  --version

# Pull secret reminder (git-ignored path per this repo's convention)
secret="$REPO_ROOT/docs/Secretes/pull-secret.txt"
if [ ! -f "$secret" ] && [ ! -f "$HOME/pull-secret.txt" ]; then
  cat <<EOF

Prereqs OK. One manual step before scripts/61-install-crc-mac.sh:
  Get your free Red Hat pull secret from
    https://console.redhat.com/openshift/create/local
  and save it as either:
    $secret          (preferred; git-ignored)
    ~/pull-secret.txt              (fallback; picked up by env override)
EOF
else
  echo
  echo "Prereqs OK. Pull secret found. Next: scripts/61-install-crc-mac.sh"
fi
