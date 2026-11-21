#!/usr/bin/env bash
# QUICK build (~10 min) from the private hardened BASE image (scripts/make-base-ami.sh),
# then publish it as a PUBLIC Community AMI and remove the previous public image.
# Usage: ./scripts/make-public-ami.sh [region] [version] [extra-region ...]
#   e.g. ./scripts/make-public-ami.sh ap-south-1 1.0.0 us-east-1
set -euo pipefail
REGION="${1:-ap-south-1}"; VERSION="${2:-$(date -u +%Y.%m.%d)}"; shift $(( $# > 2 ? 2 : $# )) || true
EXTRA_REGIONS=("$@")
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need packer

echo "==> Checking build network in $REGION"
bash scripts/ensure-build-network.sh "$REGION" >/dev/null

BASE=$(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=cis-base,public \
       --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
[ "$BASE" != None ] || { echo "No hardened image (tag Stage=cis-base or public). Run the 'Build BASE AMI' workflow first."; exit 1; }
echo "==> Quick build in $REGION (v$VERSION) from base $BASE – about 10 min"
packer init quick.pkr.hcl
packer build -color=false -var "region=$REGION" -var "version=$VERSION" quick.pkr.hcl
AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
echo "==> Built $AMI"

publish() {   # region ami
  local r=$1 a=$2
  aws ec2 wait image-available --region "$r" --image-ids "$a"
  aws ec2 disable-image-block-public-access --region "$r" >/dev/null || true
  aws ec2 modify-image-attribute --region "$r" --image-id "$a" \
    --launch-permission "Add=[{Group=all}]"
  # Public AMIs are launchable without sharing the snapshot; keep snapshot private.
  local name; name=$(aws ec2 describe-images --region "$r" --image-ids "$a" --query 'Images[0].Name' --output text)
  echo "PUBLIC  $r  $a  $name"
}

publish "$REGION" "$AMI"

# keep only the newest public image in this region
for old in $(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=public \
             --query "Images[?ImageId!='$AMI'].ImageId" --output text); do
  snaps=$(aws ec2 describe-images --region "$REGION" --image-ids "$old" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  aws ec2 deregister-image --region "$REGION" --image-id "$old"
  for s in $snaps; do aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$s" || true; done
  echo "removed previous public image $old"
done

for r in "${EXTRA_REGIONS[@]}"; do
  NAME=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" --query 'Images[0].Name' --output text)
  NEW=$(aws ec2 copy-image --region "$r" --source-region "$REGION" --source-image-id "$AMI" \
        --name "$NAME" --description "Hardened Ubuntu 24.04 LTS (security baseline) v$VERSION" \
        --copy-image-tags --query ImageId --output text)
  publish "$r" "$NEW"
done

echo
echo "Find it: EC2 → AMIs → Public images → search: ubuntu-2404-cis"
echo "Launch:  aws ec2 run-instances --region $REGION --image-id $AMI --instance-type t3.micro --key-name <key> --metadata-options HttpTokens=required"
