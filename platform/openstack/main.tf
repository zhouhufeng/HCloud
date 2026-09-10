# HCloud on OpenStack — VM layer only. The middleware (hcloud/) runs inside the VMs.
# Reference topology and rationale: docs/platforms/openstack.md §13.
terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.0" }
  }
  # backend "s3" {}   # keep state on the Ceph RGW endpoint so it survives the deploy host
}

provider "openstack" { cloud = var.cloud }   # entry in /etc/openstack/clouds.yaml

variable "cloud"        { default = "hcloud" }
variable "image_name"   { default = "ubuntu-24.04" }
variable "key_pair"     { default = "hcloud-admin" }
variable "server_count" { default = 3 }
variable "server_flavor" { default = "k3s.server" }
variable "data_disk_gb" { default = 200 }            # etcd + local-path on a host-local NVMe volume type
variable "data_volume_type" { default = "local-nvme" }
variable "k3s_token"    { sensitive = true }        # TF_VAR_k3s_token, never in git

resource "openstack_compute_servergroup_v2" "servers" {
  name     = "k3s-servers"
  policies = ["anti-affinity"]                       # three servers on three sleds, or etcd dies with one sled
}

resource "openstack_networking_network_v2" "k3s" { name = "k3s-net" }

resource "openstack_networking_subnet_v2" "k3s" {
  name            = "k3s-subnet"
  network_id      = openstack_networking_network_v2.k3s.id
  cidr            = "192.168.30.0/24"
  dns_nameservers = ["10.10.20.1"]
  # MTU comes from the network; do not set it in the guest
}

resource "openstack_networking_secgroup_v2" "nodes" { name = "k3s-nodes" }

resource "openstack_networking_secgroup_rule_v2" "node_ports" {
  for_each = { ssh = [22, 22, "tcp"], api = [6443, 6443, "tcp"], kubelet = [10250, 10250, "tcp"],
               etcd = [2379, 2380, "tcp"], vxlan = [8472, 8472, "udp"], web = [80, 443, "tcp"] }
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value[2]
  port_range_min    = each.value[0]
  port_range_max    = each.value[1]
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.nodes.id
}

resource "openstack_blockstorage_volume_v3" "server_data" {
  count       = var.server_count
  name        = "k3s-server-${count.index + 1}-data"
  size        = var.data_disk_gb
  volume_type = var.data_volume_type
}

resource "openstack_compute_instance_v2" "server" {
  count           = var.server_count
  name            = "k3s-server-${count.index + 1}"
  image_name      = var.image_name
  flavor_name     = var.server_flavor
  key_pair        = var.key_pair
  security_groups = [openstack_networking_secgroup_v2.nodes.name]
  user_data       = templatefile("${path.module}/cloud-init/node.yaml", { hostname = "k3s-server-${count.index + 1}" })
  scheduler_hints { group = openstack_compute_servergroup_v2.servers.id }
  network { uuid = openstack_networking_network_v2.k3s.id }
}

resource "openstack_compute_volume_attach_v2" "server_data" {
  count       = var.server_count
  instance_id = openstack_compute_instance_v2.server[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.server_data[count.index].id
}

output "server_ips" { value = openstack_compute_instance_v2.server[*].access_ip_v4 }
