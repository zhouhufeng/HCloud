#!/usr/bin/env bash
# Platform: AWS EC2 · 10 — launch a Linux host for the middleware.
#
# STATUS: reference implementation, not yet run. Needs the aws CLI configured.
#   HCLOUD_AWS_KEY       existing EC2 key pair name (required)
#   HCLOUD_AWS_SUBNET    subnet id (required)
#   HCLOUD_AWS_TYPE      instance type (default r6i.4xlarge — 16 vCPU / 128 GiB)
#   HCLOUD_AWS_DATA_GB   EBS gp3 data volume size (default 2000)
#   HCLOUD_AWS_NAME      Name tag (default hcloud)
set -euo pipefail
: "${HCLOUD_AWS_KEY:?set HCLOUD_AWS_KEY}" "${HCLOUD_AWS_SUBNET:?set HCLOUD_AWS_SUBNET}"
TYPE="${HCLOUD_AWS_TYPE:-r6i.4xlarge}"; DATA_GB="${HCLOUD_AWS_DATA_GB:-2000}"; NAME="${HCLOUD_AWS_NAME:-hcloud}"
command -v aws >/dev/null || { echo "ERROR: aws CLI missing"; exit 1; }

echo "==> Resolving the current Ubuntu 24.04 AMI"
AMI="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
VPC="$(aws ec2 describe-subnets --subnet-ids "$HCLOUD_AWS_SUBNET" --query 'Subnets[0].VpcId' --output text)"

echo "==> Security group $NAME-nodes (ssh in; everything else is outbound or in-cluster)"
SG="$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME-nodes" Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ -z "$SG" ] || [ "$SG" = None ]; then
  SG="$(aws ec2 create-security-group --group-name "$NAME-nodes" --description "HCloud nodes" --vpc-id "$VPC" --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG" >/dev/null   # node-to-node
fi

echo "==> Launching $TYPE ($AMI) with a ${DATA_GB} GB gp3 data volume"
ID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --key-name "$HCLOUD_AWS_KEY" \
  --subnet-id "$HCLOUD_AWS_SUBNET" --security-group-ids "$SG" --associate-public-ip-address \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\"}},{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":${DATA_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":false}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)"
aws ec2 wait instance-running --instance-ids "$ID"
IP="$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

cat <<EOF

Instance $ID running at $IP. On the host:
  ssh ubuntu@$IP
  git clone <repo> HCloud && cd HCloud
  HCLOUD_STORAGE_DEV=/dev/nvme1n1 bash platform/linux/10-host-prep.sh   # the data volume (check lsblk)
  bash hcloud/10-install-k8s.sh  # then 11..15
Terminate when done: aws ec2 terminate-instances --instance-ids $ID   (the data volume is kept)
EOF
