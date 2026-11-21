#!/usr/bin/env bash
# Monthly BASE build (~35 min): full CIS hardening + upstream OpenSSH + SSM Agent rebuild +
# single-disk layout. Result is a PRIVATE image tagged Stage=cis-base (only the newest is kept).
# Usage: ./scripts/make-base-ami.sh [region] [--from-ami ami-xxx]   (--from-ami: use an existing
#        hardened image as the base instead of building - instant bootstrap)
set -euo pipefail
REGION="${1:-ap-south-1}"; shift || true
FROM=""; [ "${1:-}" = "--from-ami" ] && FROM=$2
cd "$(dirname "$0")/.."
ARCH=${ARCH:-amd64}; [ "$ARCH" = arm64 ] && AWSARCH=arm64 || AWSARCH=x86_64

if [ -n "$FROM" ]; then
  BASE=$FROM   # just tag it; the quick build adds OpenSSH 10.x + SSM rebuild if missing
  aws ec2 delete-tags --region "$REGION" --resources "$BASE" --tags Key=Stage >/dev/null 2>&1 || true
else
  bash scripts/ensure-build-network.sh "$REGION" >/dev/null
  ansible-galaxy install -r ansible/requirements.yml -p ansible/roles --force
  ansible-galaxy collection install community.general ansible.posix
  packer init ubuntu2404-cis.pkr.hcl
  packer build -color=false -var "region=$REGION" -var "arch=$ARCH" -var "product_name=ubuntu-2404-cis-base" \
    -var "version=$(date -u +%Y.%m.%d)" ubuntu2404-cis.pkr.hcl
  BASE=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
fi
aws ec2 wait image-available --region "$REGION" --image-ids "$BASE"
aws ec2 create-tags --region "$REGION" --resources "$BASE" --tags Key=Stage,Value=cis-base
echo "BASE (private): $BASE"

# Standalone backup snapshot of the base disk: if every hardened image is deleted, the quick
# build re-registers an image from it in ~1 min instead of a 25-min full rebuild.
SRC=$(aws ec2 describe-images --region "$REGION" --image-ids "$BASE" --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
if BK=$(aws ec2 copy-snapshot --region "$REGION" --source-region "$REGION" --source-snapshot-id "$SRC" \
        --description "cis-base-backup $ARCH from $BASE" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Stage,Value=cis-base-backup},{Key=Arch,Value=$ARCH},{Key=FromAMI,Value=$BASE}]" \
        --query SnapshotId --output text 2>/dev/null); then
  echo "backup snapshot: $BK"
  for old in $(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters Name=tag:Stage,Values=cis-base-backup Name=tag:Arch,Values="$ARCH" \
               --query "Snapshots[?SnapshotId!='$BK'].SnapshotId" --output text); do
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$old" && echo "removed old backup $old"
  done
else
  echo "WARNING: could not create backup snapshot (needs ec2:CopySnapshot - re-run bootstrap/setup-aws.sh)"
fi

# keep only the newest base image
for old in $(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=cis-base Name=architecture,Values=$AWSARCH \
             --query "Images[?ImageId!='$BASE'].ImageId" --output text); do
  snaps=$(aws ec2 describe-images --region "$REGION" --image-ids "$old" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  aws ec2 deregister-image --region "$REGION" --image-id "$old"
  for s in $snaps; do aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$s" || true; done
  echo "removed old base $old"
done
