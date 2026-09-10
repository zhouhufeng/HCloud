#!/usr/bin/env python3
"""Convert an exported OpenShift (NERC) namespace -> plain Kubernetes manifests for HCloud.

Application-layer step 20. Reads  docs/Secretes/migration/<ns>/raw/*.yaml
                          writes docs/Secretes/migration/<ns>/clean/*.yaml (+ _replicas.json)

What it does (the OpenShift -> Kubernetes contract of the middleware):
  - strips cluster-specific metadata and status
  - drops OpenShift-generated secrets (SA tokens, dockercfg) and SA secret refs
  - preserves headless services (clusterIP: None), clears assigned clusterIPs/nodePorts
  - PVC storageClassName -> --storage-class (default local-path; "keep" leaves NERC's
    name, which hcloud/11-storage.sh aliases)
  - Route -> networking.k8s.io/v1 Ingress on IngressClass nginx
      edge/reencrypt -> plain TLS at ingress (default wildcard cert); passthrough -> ssl-passthrough
      hosts rewritten from <name>-<ns>.apps.shift.nerc.mghpcc.org to <name>.<--domain>
  - workloads written with replicas: 0 (scale up after data lands); originals -> _replicas.json

Usage: 20-convert-manifests.py [--ns favor-4ee4be] [--domain hcloud.example.org] [--storage-class local-path|keep]
"""
import argparse, json, os, sys, yaml

DROP_META = {"uid","resourceVersion","creationTimestamp","generation","selfLink","managedFields","ownerReferences"}
DROP_ANNO_PREFIX = ("kubectl.kubernetes.io/","openshift.io/","k8s.ovn.org/","pv.kubernetes.io/",
                    "volume.kubernetes.io/","volume.beta.kubernetes.io/","operator.")
NERC_APPS_SUFFIX = ".apps.shift.nerc.mghpcc.org"

class Converter:
    def __init__(self, ns, raw, clean, domain, storage_class):
        self.ns, self.raw, self.clean, self.domain, self.sc = ns, raw, clean, domain, storage_class
        os.makedirs(clean, exist_ok=True)
        self.replicas = {}

    # -- helpers -------------------------------------------------------------
    def clean_meta(self, m):
        for k in list(m):
            if k in DROP_META: del m[k]
        m["namespace"] = self.ns
        a = m.get("annotations")
        if a:
            for k in list(a):
                if k.startswith(DROP_ANNO_PREFIX): del a[k]
            if not a: del m["annotations"]
        return m

    def load(self, kind):
        for name in (kind, {"persistentvolumeclaim": "pvc"}.get(kind, kind)):
            p = os.path.join(self.raw, name + ".yaml")
            if os.path.exists(p): break
        else:
            return []
        with open(p) as f: doc = yaml.safe_load(f)
        if not doc: return []
        return doc["items"] if "items" in doc else [doc]

    def dump(self, name, objs):
        objs = [o for o in objs if o]
        if not objs: return 0
        with open(os.path.join(self.clean, name), "w") as f:
            yaml.safe_dump_all(objs, f, default_flow_style=False, sort_keys=False)
        return len(objs)

    def set_sc(self, spec):
        if self.sc != "keep": spec["storageClassName"] = self.sc

    def rewrite_host(self, host):
        if not host: return host
        suffix = f"-{self.ns}{NERC_APPS_SUFFIX}"
        if host.endswith(suffix):
            base = host[:-len(suffix)]
            return f"{base}.{self.domain}" if self.domain else host
        if self.domain and not host.endswith(self.domain):     # custom domains, e.g. api-v2.genohub.org
            return f"{host.split('.')[0]}.{self.domain}"
        return host

    # -- kinds ---------------------------------------------------------------
    def secrets(self):
        out = []
        for o in self.load("secret"):
            t = o.get("type",""); n = o["metadata"]["name"]
            if t in ("kubernetes.io/service-account-token","kubernetes.io/dockercfg"): continue
            if n.endswith(("-token","-dockercfg")) or n in ("builder-dockercfg","default-dockercfg","deployer-dockercfg"): continue
            o.pop("status",None); self.clean_meta(o["metadata"]); out.append(o)
        return self.dump("10-secrets.yaml", out)

    def configmaps(self):
        out = []
        for o in self.load("configmap"):
            if o["metadata"]["name"].startswith(("kube-root-ca","openshift-service-ca","odh-","config-service-ca","config-trusted-ca")): continue
            o.pop("status",None); self.clean_meta(o["metadata"]); out.append(o)
        return self.dump("11-configmaps.yaml", out)

    def serviceaccounts(self):
        out = []
        for o in self.load("serviceaccount"):
            if o["metadata"]["name"] in ("default","builder","deployer","pipeline"): continue
            for k in ("secrets","imagePullSecrets","status"): o.pop(k,None)
            self.clean_meta(o["metadata"]); out.append(o)
        return self.dump("12-serviceaccounts.yaml", out)

    def services(self):
        out = []
        for o in self.load("service"):
            sp = o.get("spec",{}); o.pop("status",None); self.clean_meta(o["metadata"])
            headless = sp.get("clusterIP") == "None"
            for k in ("clusterIP","clusterIPs","ipFamilies","ipFamilyPolicy","externalIPs","loadBalancerIP"): sp.pop(k,None)
            if headless: sp["clusterIP"] = "None"
            for port in sp.get("ports",[]) or []: port.pop("nodePort",None)
            out.append(o)
        return self.dump("13-services.yaml", out)

    def pvcs(self):
        out = []
        for o in self.load("persistentvolumeclaim"):
            sp = o.get("spec",{}); o.pop("status",None); self.clean_meta(o["metadata"])
            sp.pop("volumeName",None); sp.pop("volumeMode",None); self.set_sc(sp)
            out.append(o)
        return self.dump("14-pvcs.yaml", out)

    def rbac(self):
        n = 0
        for kind, fname in (("role","15-roles.yaml"),("rolebinding","16-rolebindings.yaml")):
            out = []
            for o in self.load(kind):
                o.pop("status",None); self.clean_meta(o["metadata"]); out.append(o)
            n += self.dump(fname, out)
        return n

    def workloads(self):
        n = 0
        for kind, fname in (("deployment","20-deployments.yaml"),("statefulset","21-statefulsets.yaml"),
                            ("daemonset","22-daemonsets.yaml"),("cronjob","23-cronjobs.yaml")):
            out = []
            for o in self.load(kind):
                name = o["metadata"]["name"]; o.pop("status",None); self.clean_meta(o["metadata"])
                sp = o.get("spec",{})
                if "replicas" in sp or kind in ("deployment","statefulset"):
                    self.replicas[f"{kind}/{name}"] = sp.get("replicas",1); sp["replicas"] = 0
                tmeta = sp.get("template",{}).get("metadata",{})
                if tmeta.get("annotations"):
                    for k in list(tmeta["annotations"]):
                        if k.startswith(DROP_ANNO_PREFIX): del tmeta["annotations"][k]
                    if not tmeta["annotations"]: del tmeta["annotations"]
                for vct in sp.get("volumeClaimTemplates",[]) or []:
                    vct.pop("status",None); vct.get("metadata",{}).pop("creationTimestamp",None)
                    vct.setdefault("spec",{}).pop("volumeMode",None); self.set_sc(vct["spec"])
                out.append(o)
            n += self.dump(fname, out)
        return n

    def routes(self):
        out = []
        for o in self.load("route"):
            sp = o.get("spec",{}); name = o["metadata"]["name"]
            host = self.rewrite_host(sp.get("host",""))
            term = (sp.get("tls") or {}).get("termination")
            svc = sp.get("to",{}).get("name"); tp = sp.get("port",{}).get("targetPort")
            anno = {}
            if term == "passthrough":
                anno["nginx.ingress.kubernetes.io/ssl-passthrough"] = "true"
                anno["nginx.ingress.kubernetes.io/backend-protocol"] = "HTTPS"
            elif term == "reencrypt":
                anno["nginx.ingress.kubernetes.io/backend-protocol"] = "HTTPS"
            if isinstance(tp,int) or str(tp).isdigit(): port = {"number": int(tp)}
            else: port = {"name": tp}
            out.append({"apiVersion":"networking.k8s.io/v1","kind":"Ingress",
                        "metadata":{"name":name,"namespace":self.ns,
                                    "labels":o["metadata"].get("labels",{}),
                                    "annotations":{**anno, "hcloud.io/nerc-host": sp.get("host","")}},
                        "spec":{"ingressClassName":"nginx",
                                "rules":[{"host":host,"http":{"paths":[{"path":"/","pathType":"Prefix",
                                         "backend":{"service":{"name":svc,"port":port}}}]}}]}})
        return self.dump("30-ingress.yaml", out)

    def run(self):
        for label, fn in (("secrets",self.secrets),("configmaps",self.configmaps),("serviceaccts",self.serviceaccounts),
                          ("services",self.services),("pvcs",self.pvcs),("rbac",self.rbac),
                          ("workloads",self.workloads),("routes->ingress",self.routes)):
            print(f"  {label:<15}{fn()}")
        with open(os.path.join(self.clean,"_replicas.json"),"w") as f: json.dump(self.replicas, f, indent=2, sort_keys=True)
        print("  original replicas saved to _replicas.json")
        print("  SKIPPED (OpenShift-only): imagestream, buildconfig, job, pdb — handle separately if needed")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ns", default=os.environ.get("HCLOUD_NS","favor-4ee4be"))
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--domain", default=os.environ.get("HCLOUD_DOMAIN",""), help="rewrite Ingress hosts to <name>.<domain>; empty keeps NERC hosts")
    ap.add_argument("--storage-class", default="local-path", help="PVC storageClassName, or 'keep'")
    a = ap.parse_args()
    base = os.path.join(a.repo,"docs","Secretes","migration",a.ns)
    raw, clean = os.path.join(base,"raw"), os.path.join(base,"clean")
    if not os.path.isdir(raw): sys.exit(f"ERROR: no raw export at {raw} — run apps/nerc-migration/10-export-nerc.sh first")
    print(f"==> {a.ns}: {raw} -> {clean} (domain={a.domain or 'unchanged'}, storageClass={a.storage_class})")
    Converter(a.ns, raw, clean, a.domain, a.storage_class).run()
    print(f"==> Done. Apply with: apps/nerc-migration/30-apply.sh {a.ns}")

if __name__ == "__main__": main()
