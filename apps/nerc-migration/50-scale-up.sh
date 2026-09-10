#!/usr/bin/env bash
# Application layer · 50 — after the data is in place, restore the original replica counts.
# Reads docs/Secretes/migration/<ns>/<variant>/_replicas.json written by the converter.
# Usage: 50-scale-up.sh [namespace]
#   HCLOUD_MANIFEST_VARIANT=clean (default; Kubernetes) | crc (Mac OpenShift PoC, uses oc)
set -euo pipefail
. "$(dirname "$0")/../../hcloud/lib.sh"; hc_load_env
NS="${1:-$HCLOUD_NS}"; VARIANT="${HCLOUD_MANIFEST_VARIANT:-clean}"
MAP="$HCLOUD_SECRETS/migration/$NS/$VARIANT/_replicas.json"
[ -f "$MAP" ] || hc_die "$MAP not found — run the converter first"

if [ "$VARIANT" = crc ]; then
  K=oc; [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null && eval "$(crc oc-env)"
else
  hc_setup_kubectl; K=kubectl
fi
python3 - "$MAP" "$NS" "$K" <<'PY'
import json, subprocess, sys
mp, ns, k = sys.argv[1:4]
for key, r in json.load(open(mp)).items():
    kind, name = key.split("/", 1)
    if int(r) <= 0: continue
    print(f"==> {kind}/{name} -> {r}")
    subprocess.run([k, "-n", ns, "scale", f"{kind}/{name}", "--replicas", str(r)], check=False)
PY
echo "Done. Watch: $K -n $NS get pods -w"
