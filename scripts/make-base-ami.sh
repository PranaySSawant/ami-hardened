#!/usr/bin/env bash
# Monthly BASE build (~35 min): full CIS hardening + upstream OpenSSH + SSM Agent rebuild +
# single-disk layout. Result is a PRIVATE image tagged Stage=cis-base (only the newest is kept).
# Usage: ./scripts/make-base-ami.sh [region] [--from-ami ami-xxx]   (--from-ami: copy an existing
#        hardened image instead of building - used once to bootstrap)
set -euo pipefail
REGION="${1:-ap-south-1}"; shift || true
FROM=""; [ "${1:-}" = "--from-ami" ] && FROM=$2
cd "$(dirname "$0")/.."
TS=$(date -u +%Y%m%d-%H%M)

if [ -n "$FROM" ]; then
  BASE=$(aws ec2 copy-image --region "$REGION" --source-region "$REGION" --source-image-id "$FROM" \
         --name "ubuntu-2404-cis-base-$TS" --description "PRIVATE hardened base for quick builds" \
         --query ImageId --output text)
else
  bash scripts/ensure-build-network.sh "$REGION" >/dev/null
  ansible-galaxy install -r ansible/requirements.yml -p ansible/roles --force
  ansible-galaxy collection install community.general ansible.posix
  packer init ubuntu2404-cis.pkr.hcl
  packer build -color=false -var "region=$REGION" -var "product_name=ubuntu-2404-cis-base" \
    -var "version=$(date -u +%Y.%m.%d)" ubuntu2404-cis.pkr.hcl
  BASE=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
fi
aws ec2 wait image-available --region "$REGION" --image-ids "$BASE"
aws ec2 create-tags --region "$REGION" --resources "$BASE" --tags Key=Stage,Value=cis-base
echo "BASE (private): $BASE"

# keep only the newest base image
for old in $(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=cis-base \
             --query "Images[?ImageId!='$BASE'].ImageId" --output text); do
  snaps=$(aws ec2 describe-images --region "$REGION" --image-ids "$old" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  aws ec2 deregister-image --region "$REGION" --image-id "$old"
  for s in $snaps; do aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$s" || true; done
  echo "removed old base $old"
done
