#!/usr/bin/env python3
"""Convert exported OpenShift (NERC) manifests -> clean RKE2/k8s manifests.
Reads docs/Secretes/migration/favor-4ee4be/raw/*.yaml, writes .../clean/*.yaml.
- strips cluster-specific metadata + status
- drops OpenShift-generated secrets (SA tokens, dockercfg) and SA secret refs
- preserves headless services (clusterIP: None), clears assigned clusterIPs
- PVC storageClassName -> local-path
- Route -> networking.k8s.io/v1 Ingress (edge/reencrypt -> TLS; passthrough -> nginx ssl-passthrough)
- workloads written with replicas: 0 (scale up after data migration); originals recorded
"""
import os, sys, yaml, json

BASE = os.path.join(os.path.dirname(__file__), "..", "docs", "Secretes", "migration", "favor-4ee4be")
RAW = os.path.join(BASE, "raw"); CLEAN = os.path.join(BASE, "clean")
NS = "favor-4ee4be"
os.makedirs(CLEAN, exist_ok=True)

DROP_META = {"uid","resourceVersion","creationTimestamp","generation","selfLink","managedFields","ownerReferences"}
DROP_ANNO_PREFIX = ("kubectl.kubernetes.io/","openshift.io/","k8s.ovn.org/","pv.kubernetes.io/",
                    "volume.kubernetes.io/","volume.beta.kubernetes.io/","operator.")

def clean_meta(m):
    for k in list(m):
        if k in DROP_META: del m[k]
    m["namespace"] = NS
    a = m.get("annotations")
    if a:
        for k in list(a):
            if k.startswith(DROP_ANNO_PREFIX): del a[k]
        if not a: del m["annotations"]
    return m

def load(kind):
    p = os.path.join(RAW, kind + ".yaml")
    if not os.path.exists(p): return []
    with open(p) as f: doc = yaml.safe_load(f)
    if not doc: return []
    return doc.get("items", [doc]) if doc.get("kind","").endswith("List") or "items" in doc else [doc]

def dump(name, objs):
    objs = [o for o in objs if o]
    if not objs: return 0
    with open(os.path.join(CLEAN, name), "w") as f:
        yaml.safe_dump_all(objs, f, default_flow_style=False, sort_keys=False)
    return len(objs)

replicas_note = {}

def do_secrets():
    out=[]
    for o in load("secret"):
        t=o.get("type",""); n=o["metadata"]["name"]
        if t in ("kubernetes.io/service-account-token","kubernetes.io/dockercfg"): continue
        if n.endswith("-token") or n in ("builder-dockercfg","default-dockercfg","deployer-dockercfg"): continue
        o.pop("status",None); clean_meta(o["metadata"]); out.append(o)
    return dump("10-secrets.yaml", out)

def do_configmaps():
    out=[]
    for o in load("configmap"):
        if o["metadata"]["name"].startswith(("kube-root-ca","openshift-service-ca")): continue
        o.pop("status",None); clean_meta(o["metadata"]); out.append(o)
    return dump("11-configmaps.yaml", out)

def do_sa():
    out=[]
    for o in load("serviceaccount"):
        if o["metadata"]["name"]=="default": continue
        o.pop("secrets",None); o.pop("imagePullSecrets",None); o.pop("status",None)
        clean_meta(o["metadata"]); out.append(o)
    return dump("12-serviceaccounts.yaml", out)

def do_services():
    out=[]
    for o in load("service"):
        sp=o.get("spec",{}); o.pop("status",None); clean_meta(o["metadata"])
        headless = sp.get("clusterIP")=="None"
        for k in ("clusterIP","clusterIPs","ipFamilies","ipFamilyPolicy","externalIPs","loadBalancerIP"):
            sp.pop(k,None)
        if headless: sp["clusterIP"]="None"
        for port in sp.get("ports",[]): port.pop("nodePort",None)
        out.append(o)
    return dump("13-services.yaml", out)

def do_pvcs():
    out=[]
    for o in load("persistentvolumeclaim"):
        sp=o.get("spec",{}); o.pop("status",None); clean_meta(o["metadata"])
        sp.pop("volumeName",None); sp.pop("volumeMode",None)
        sp["storageClassName"]="local-path"
        out.append(o)
    return dump("14-pvcs.yaml", out)

def do_routes():
    out=[]
    for o in load("route"):
        sp=o.get("spec",{}); name=o["metadata"]["name"]; host=sp.get("host","")
        tls=sp.get("tls",{}) or {}; term=tls.get("termination")
        svc=sp.get("to",{}).get("name"); tp=sp.get("port",{}).get("targetPort")
        anno={}
        if term=="passthrough":
            anno["nginx.ingress.kubernetes.io/ssl-passthrough"]="true"
            anno["nginx.ingress.kubernetes.io/backend-protocol"]="HTTPS"
        elif term=="reencrypt":
            anno["nginx.ingress.kubernetes.io/backend-protocol"]="HTTPS"
        if isinstance(tp,int):        port={"number":tp}
        elif str(tp).isdigit():       port={"number":int(tp)}
        else:                         port={"name":tp}
        ing={"apiVersion":"networking.k8s.io/v1","kind":"Ingress",
             "metadata":{"name":name,"namespace":NS,"annotations":anno,
                         "labels":o["metadata"].get("labels",{})},
             "spec":{"ingressClassName":"nginx",
                     "rules":[{"host":host,"http":{"paths":[
                        {"path":"/","pathType":"Prefix",
                         "backend":{"service":{"name":svc,"port":port}}}]}}]}}
        out.append(ing)
    return dump("30-ingress.yaml", out)

def do_workloads():
    n=0
    for kind,fname in (("deployment","20-deployments.yaml"),("statefulset","21-statefulsets.yaml")):
        out=[]
        for o in load(kind):
            name=o["metadata"]["name"]; o.pop("status",None); clean_meta(o["metadata"])
            sp=o.get("spec",{})
            replicas_note[f"{kind}/{name}"]=sp.get("replicas",1)
            sp["replicas"]=0
            # strip openshift-injected pod annotations
            tmeta=sp.get("template",{}).get("metadata",{})
            if tmeta.get("annotations"):
                for k in list(tmeta["annotations"]):
                    if k.startswith(DROP_ANNO_PREFIX): del tmeta["annotations"][k]
                if not tmeta["annotations"]: del tmeta["annotations"]
            # clean volumeClaimTemplates (statefulset)
            for vct in sp.get("volumeClaimTemplates",[]) or []:
                vct.pop("status",None)
                vct.get("metadata",{}).pop("creationTimestamp",None)
                vct.setdefault("spec",{})["storageClassName"]="local-path"
                vct["spec"].pop("volumeMode",None)
            out.append(o)
        n+=dump(fname,out)
    return n

if __name__=="__main__":
    print("secrets     ", do_secrets())
    print("configmaps  ", do_configmaps())
    print("serviceaccts", do_sa())
    print("services    ", do_services())
    print("pvcs        ", do_pvcs())
    print("routes->ing ", do_routes())
    print("workloads   ", do_workloads())
    with open(os.path.join(CLEAN,"_replicas.json"),"w") as f: json.dump(replicas_note,f,indent=2)
    print("original replicas saved to clean/_replicas.json")
    print("SKIPPED (OpenShift-only / handle separately): imagestream, buildconfig, job, pdb, role, rolebinding, ES CR")
