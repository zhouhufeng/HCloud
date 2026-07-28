#!/usr/bin/env python3
"""Convert NERC OpenShift exports -> apply-ready manifests for CRC on the Mac.

CRC is OpenShift, so this is a much lighter conversion than 50-convert-manifests.py
(which retargets to RKE2 nginx). Here we:

  - strip cluster-specific metadata (uid, resourceVersion, generated fields)
  - drop OpenShift-generated per-namespace secrets and SA token/dockercfg secrets
  - keep Routes as Routes (unchanged apart from host rewriting to $HCLOUD_DOMAIN)
  - keep OpenShift-native resources (BuildConfig, ImageStream) as-is
  - preserve the NERC storageClassName; script 64 aliases the class name locally
  - scale workloads to replicas: 0 so PVC data can be migrated before pods boot
  - record original replicas in _replicas.json for later scale-up
  - rewrite Route hosts from *.apps.shift.nerc.mghpcc.org  ->  *.apps-crc.testing
    and any custom-domain routes to *.$HCLOUD_DOMAIN (if set)

Reads : docs/Secretes/migration/<ns>/raw/*.yaml
Writes: docs/Secretes/migration/<ns>/crc/*.yaml + _replicas.json
"""
import argparse, json, os, re, sys, yaml

DROP_META = {"uid","resourceVersion","creationTimestamp","generation",
             "selfLink","managedFields","ownerReferences"}
DROP_ANNO_PREFIX = ("kubectl.kubernetes.io/","openshift.io/generated-by",
                    "k8s.ovn.org/","pv.kubernetes.io/","volume.kubernetes.io/",
                    "volume.beta.kubernetes.io/")
NERC_ROUTE_SUFFIX = "-favor-4ee4be.apps.shift.nerc.mghpcc.org"

def clean_meta(m, ns):
    for k in list(m):
        if k in DROP_META: del m[k]
    m["namespace"] = ns
    a = m.get("annotations")
    if a:
        for k in list(a):
            if any(k.startswith(p) for p in DROP_ANNO_PREFIX): del a[k]
        if not a: del m["annotations"]
    return m

def load(raw_dir, kind):
    p = os.path.join(raw_dir, kind + ".yaml")
    if not os.path.exists(p): return []
    with open(p) as f: doc = yaml.safe_load(f)
    if not doc: return []
    if "items" in doc: return doc["items"]
    return [doc]

def dump(clean_dir, name, objs):
    objs = [o for o in objs if o]
    if not objs: return 0
    with open(os.path.join(clean_dir, name), "w") as f:
        yaml.safe_dump_all(objs, f, default_flow_style=False, sort_keys=False)
    return len(objs)

def convert(ns, raw_dir, clean_dir, hcloud_domain):
    os.makedirs(clean_dir, exist_ok=True)
    replicas = {}

    # Secrets — strip OpenShift-managed types
    out = []
    for o in load(raw_dir, "secret"):
        t = o.get("type","")
        n = o["metadata"]["name"]
        if t in ("kubernetes.io/service-account-token","kubernetes.io/dockercfg"):
            continue
        if n in ("builder-dockercfg","default-dockercfg","deployer-dockercfg"):
            continue
        if n.endswith("-token") or n.endswith("-dockercfg"):
            continue
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_sec = dump(clean_dir, "10-secrets.yaml", out)

    # ConfigMaps — drop OpenShift-provided
    out = []
    for o in load(raw_dir, "configmap"):
        n = o["metadata"]["name"]
        if n.startswith(("kube-root-ca","openshift-service-ca","odh-trusted-ca","odh-kserve","config-service-ca","config-trusted-ca")):
            continue
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_cm = dump(clean_dir, "11-configmaps.yaml", out)

    # ServiceAccounts — drop default, strip generated refs
    out = []
    for o in load(raw_dir, "serviceaccount"):
        if o["metadata"]["name"] in ("default","builder","deployer","pipeline"): continue
        o.pop("secrets", None); o.pop("imagePullSecrets", None); o.pop("status", None)
        clean_meta(o["metadata"], ns); out.append(o)
    n_sa = dump(clean_dir, "12-serviceaccounts.yaml", out)

    # Services — clear assigned IPs, keep headless
    out = []
    for o in load(raw_dir, "service"):
        sp = o.get("spec", {}); o.pop("status", None); clean_meta(o["metadata"], ns)
        headless = (sp.get("clusterIP") == "None")
        for k in ("clusterIP","clusterIPs","ipFamilies","ipFamilyPolicy","externalIPs","loadBalancerIP"):
            sp.pop(k, None)
        if headless: sp["clusterIP"] = "None"
        for port in sp.get("ports", []) or []: port.pop("nodePort", None)
        out.append(o)
    n_svc = dump(clean_dir, "13-services.yaml", out)

    # PVCs — strip volumeName/volumeMode; keep storageClassName (script 64 aliases the name)
    # (Raw export names it 'pvc.yaml'; try both.)
    out = []
    _pvcs = load(raw_dir, "persistentvolumeclaim") or load(raw_dir, "pvc")
    for o in _pvcs:
        sp = o.get("spec", {}); o.pop("status", None); clean_meta(o["metadata"], ns)
        sp.pop("volumeName", None); sp.pop("volumeMode", None)
        out.append(o)
    n_pvc = dump(clean_dir, "14-pvcs.yaml", out)

    # Roles / RoleBindings
    out = []
    for o in load(raw_dir, "role"):
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_role = dump(clean_dir, "15-roles.yaml", out)
    out = []
    for o in load(raw_dir, "rolebinding"):
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_rb = dump(clean_dir, "16-rolebindings.yaml", out)

    # ImageStreams + BuildConfigs — CRC has these natively
    out = []
    for o in load(raw_dir, "imagestream"):
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_is = dump(clean_dir, "17-imagestreams.yaml", out)
    out = []
    for o in load(raw_dir, "buildconfig"):
        o.pop("status", None); clean_meta(o["metadata"], ns); out.append(o)
    n_bc = dump(clean_dir, "18-buildconfigs.yaml", out)

    # Workloads — replicas -> 0 (scale up after data migration)
    for kind, fname in (("deployment","20-deployments.yaml"),
                        ("statefulset","21-statefulsets.yaml"),
                        ("daemonset","22-daemonsets.yaml"),
                        ("cronjob","23-cronjobs.yaml"),
                        ("job","24-jobs.yaml")):
        out = []
        for o in load(raw_dir, kind):
            name = o["metadata"]["name"]; o.pop("status", None); clean_meta(o["metadata"], ns)
            sp = o.get("spec", {})
            if "replicas" in sp:
                replicas[f"{kind}/{name}"] = sp["replicas"]
                sp["replicas"] = 0
            tmeta = sp.get("template", {}).get("metadata", {})
            if tmeta.get("annotations"):
                for k in list(tmeta["annotations"]):
                    if any(k.startswith(p) for p in DROP_ANNO_PREFIX):
                        del tmeta["annotations"][k]
                if not tmeta["annotations"]: del tmeta["annotations"]
            for vct in sp.get("volumeClaimTemplates", []) or []:
                vct.pop("status", None)
                vct.get("metadata", {}).pop("creationTimestamp", None)
            out.append(o)
        dump(clean_dir, fname, out)

    # Routes — rewrite hosts, keep as OpenShift Routes (CRC supports them natively)
    out = []
    for o in load(raw_dir, "route"):
        sp = o.get("spec", {}); host = sp.get("host", "")
        clean_meta(o["metadata"], ns); o.pop("status", None)
        if host.endswith(NERC_ROUTE_SUFFIX):
            # NERC apps.shift.nerc.mghpcc.org  ->  apps-crc.testing (default local)
            # If HCLOUD_DOMAIN is set, use that public domain instead.
            base = host[:-len(NERC_ROUTE_SUFFIX)]
            if hcloud_domain:
                sp["host"] = f"{base}.{hcloud_domain}"
            else:
                sp["host"] = f"{base}.apps-crc.testing"
        elif hcloud_domain and host and not host.endswith(hcloud_domain):
            # Custom-domain routes (like api-v2.genohub.org) — rewrite to sub of HCLOUD_DOMAIN
            sub = host.split(".")[0]
            sp["host"] = f"{sub}.{hcloud_domain}"
        out.append(o)
    n_route = dump(clean_dir, "30-routes.yaml", out)

    # Save the replica map for later scale-up
    with open(os.path.join(clean_dir, "_replicas.json"), "w") as f:
        json.dump(replicas, f, indent=2, sort_keys=True)

    print(f"  secrets:{n_sec}  cm:{n_cm}  sa:{n_sa}  svc:{n_svc}  pvc:{n_pvc}  "
          f"role:{n_role}  rb:{n_rb}  is:{n_is}  bc:{n_bc}  route:{n_route}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ns", default="favor-4ee4be")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--domain", default=os.environ.get("HCLOUD_DOMAIN",""),
                    help="Rewrite Route hosts to *.<domain>. Empty = keep apps-crc.testing.")
    args = ap.parse_args()

    raw = os.path.join(args.repo, "docs", "Secretes", "migration", args.ns, "raw")
    clean = os.path.join(args.repo, "docs", "Secretes", "migration", args.ns, "crc")
    if not os.path.isdir(raw):
        print(f"ERROR: no raw exports at {raw}. Run scripts/30-export-nerc.sh first.")
        sys.exit(1)
    print(f"==> Converting {args.ns} raw -> {clean} (domain={args.domain or 'apps-crc.testing'})")
    convert(args.ns, raw, clean, args.domain)
    print(f"==> Done. Apply order: oc apply -f {clean}/  (numeric prefixes give ordering)")

if __name__ == "__main__":
    main()
