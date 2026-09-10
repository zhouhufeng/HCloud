# `platform/` — the hosting layer

HCloud does not care what it runs on. This directory holds the one thing that *does*
differ per hosting platform: getting from nothing to **a Linux host (or several) that
satisfies the platform contract**, so that `hcloud/` can take over.

## The contract a platform must deliver

| Requirement | Why the middleware needs it |
|---|---|
| Linux x86_64 or arm64 with `sudo`, `curl`, `systemd` | K3s/RKE2 install and service management |
| A big, persistent directory mounted at `HCLOUD_STORAGE_DIR` | where `local-path` PVs live (HDD, NVMe RAID, Cinder/EBS volume — the platform's choice) |
| Nodes reach each other on 6443, 10250, 8472/udp (flannel VXLAN) | multi-node clusters |
| Outbound internet (HTTPS) | image pulls, Let's Encrypt, Cloudflare Tunnel — **no inbound port or static IP is ever required** |
| `hcloud/hcloud.env` written with the values above | the only thing `hcloud/` reads |

Anything richer a platform offers (a cloud load balancer, a CSI driver, GPU passthrough)
is wired in **after** the middleware, by a `platform/<name>/2x-*.sh` add-on that adjusts
the cluster to use it. The application layer never sees the difference.

## Platforms

| Directory | Hosting platform | Middleware | Status |
|---|---|---|---|
| `linux/` | **Any Linux host** — bare metal (the `pc` box, a Dell sled) or a VM you already have | K3s (RKE2 on the existing `pc`) | ✅ validated on `pc` (RKE2, 7 TiB migrated) — `docs/platforms/linux-baremetal.md` |
| `mac/` | **Mac Studio** via a Lima Linux VM | K3s inside the VM | ⬜ reference, not yet exercised — `docs/platforms/mac-studio.md` |
| `mac/crc/` | Mac Studio via **OpenShift Local (CRC)** — the pre-middleware OpenShift flavour | (none — OpenShift replaces it) | ✅ validated 2026-07 (kept as-is; superseded by K3s) |
| `openstack/` | **OpenStack VMs** — on the purchased Dell MX7000 (`docs/platforms/openstack.md`) or any other cloud | K3s on VMs + Cinder CSI add-on | ⬜ designed; hardware racked |
| `aws/` | **AWS EC2** | K3s on EC2 + EBS data volume | ⬜ reference |
| `legacy/crc-linux/` | CRC on a Linux desktop (the first 2026-07 experiments) | — | archived |

Bare-metal K3s directly on the Dell blades needs nothing beyond `linux/`: prep each sled,
run the middleware with `HCLOUD_HA=true` on the first, join the rest.

## Adding a platform

1. `platform/<name>/10-*.sh` (or Terraform): create the host(s), mount storage at
   `HCLOUD_STORAGE_DIR`, open the node ports, write `hcloud/hcloud.env`.
2. Run `platform/linux/10-host-prep.sh` on each host if it is a plain Linux box.
3. Run the middleware. Verify the cluster with `kubectl get nodes,sc,ingressclass`.
4. Optional `platform/<name>/2x-*.sh` add-ons for platform extras.
5. A page under `docs/platforms/<name>.md`: what was built, what the platform cannot do.
