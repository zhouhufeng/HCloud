# Platform: AWS EC2 (reference)

HCloud on rented VMs: `platform/aws/10-ec2.sh` launches one Ubuntu 24.04 instance with an
EBS data volume; from there the standard Linux quick start applies. Not yet run — it exists
to keep the middleware honest about platform neutrality and as a burst/staging option.

Why not production: the Dell purchase exists precisely to avoid a recurring cloud bill and
egress fees on ~8 TiB. A comparable instance (`r6i.8xlarge` + 8 TB gp3) is on the order
of $2k/month on-demand.

What the platform gives for free that we do not need: a cloud load balancer and Elastic
IP. The in-cluster Cloudflare Tunnel makes them unnecessary — the only inbound rule is ssh.
What it can add later via a `platform/aws/2x-*.sh` add-on: the AWS cloud controller and EBS
CSI for dynamically provisioned PVs instead of `local-path` on one volume.
