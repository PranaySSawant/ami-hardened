#!/usr/bin/env bash
# Ensure a public build subnet tagged Name=packer-build exists in the region.
# Creates VPC + IGW + subnet + default route if missing (all free). Idempotent.
# Usage: scripts/ensure-build-network.sh [region]     -> prints the subnet id
set -euo pipefail
R="${1:-${AWS_REGION:-ap-south-1}}"
TAG=packer-build
CIDR=10.99.0.0/24
log() { echo "[build-network] $*" >&2; }

SUB=$(aws ec2 describe-subnets --region "$R" \
  --filters Name=tag:Name,Values=$TAG Name=state,Values=available \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
if [[ "$SUB" == subnet-* ]]; then log "using $SUB"; echo "$SUB"; exit 0; fi

log "no '$TAG' subnet in $R – creating network"

# VPC (reuse a tagged one if a previous partial run left it)
VPC=$(aws ec2 describe-vpcs --region "$R" --filters Name=tag:Name,Values=$TAG \
  --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC" != vpc-* ]]; then
  VPC=$(aws ec2 create-vpc --region "$R" --cidr-block $CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG}]" \
    --query Vpc.VpcId --output text)
  aws ec2 wait vpc-available --region "$R" --vpc-ids "$VPC"
fi
aws ec2 modify-vpc-attribute --region "$R" --vpc-id "$VPC" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$R" --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'

# Internet gateway
IGW=$(aws ec2 describe-internet-gateways --region "$R" \
  --filters Name=attachment.vpc-id,Values="$VPC" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
if [[ "$IGW" != igw-* ]]; then
  IGW=$(aws ec2 create-internet-gateway --region "$R" \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TAG}]" \
    --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --region "$R" --vpc-id "$VPC" --internet-gateway-id "$IGW"
fi

# Subnet in the first AZ that offers the build instance type
# (must offer both the x86 and the Graviton build types)
AZ=$(for t in c7i.2xlarge c7g.2xlarge; do aws ec2 describe-instance-type-offerings --region "$R" --location-type availability-zone \
  --filters Name=instance-type,Values="$t" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort -u; done \
  | sort | uniq -d | head -1)
AZ=${AZ:-${R}a}
SUB=$(aws ec2 create-subnet --region "$R" --vpc-id "$VPC" --cidr-block $CIDR --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG}]" \
  --query Subnet.SubnetId --output text)
aws ec2 wait subnet-available --region "$R" --subnet-ids "$SUB"
aws ec2 modify-subnet-attribute --region "$R" --subnet-id "$SUB" --map-public-ip-on-launch

# Default route on the VPC main route table
RT=$(aws ec2 describe-route-tables --region "$R" \
  --filters Name=vpc-id,Values="$VPC" Name=association.main,Values=true \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --region "$R" --route-table-id "$RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null 2>&1 || \
aws ec2 replace-route --region "$R" --route-table-id "$RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

log "created $SUB in $AZ ($VPC, $IGW)"
echo "$SUB"
