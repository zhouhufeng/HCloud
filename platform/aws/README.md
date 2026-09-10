# Platform: AWS EC2

HCloud on rented VMs. Useful as a burst or staging environment, or to prove the
middleware really is platform-neutral: the same `hcloud/` scripts, the same converted
manifests, the same public domain — only the host changes.

**Status:** reference implementation, not yet run. Costs real money (a single
`r6i.8xlarge` with 8 TB gp3 is roughly $2k/month on-demand); the point of owning the Dell
hardware is not to pay this continuously.

| File | Purpose |
|---|---|
| `10-ec2.sh` | Launch one Ubuntu 24.04 instance with an EBS data volume and the node security group; prints the ssh + next steps |

```bash
AWS_PROFILE=hcloud HCLOUD_AWS_KEY=my-keypair HCLOUD_AWS_SUBNET=subnet-… bash platform/aws/10-ec2.sh
ssh ubuntu@<ip>
  git clone <this repo> && cd HCloud
  HCLOUD_STORAGE_DEV=/dev/nvme1n1 bash platform/linux/10-host-prep.sh     # formats+mounts the EBS volume
  bash hcloud/10-install-k8s.sh && bash hcloud/11-storage.sh && bash hcloud/12-ingress-tls.sh && bash hcloud/13-public-tunnel.sh
```

Platform-specific notes: with `HCLOUD_INGRESS_SVC_TYPE=LoadBalancer`, K3s's built-in
servicelb binds the node's IP, which is all the in-cluster Cloudflare Tunnel needs — no
ELB, no Elastic IP, no inbound security-group rule beyond ssh. Use the AWS cloud
controller + EBS CSI only if you want dynamically provisioned EBS PVs instead of
`local-path` on the one data volume.
