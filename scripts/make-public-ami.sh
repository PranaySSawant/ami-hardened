#!/usr/bin/env bash
# QUICK build (~10 min) from the private hardened BASE image (scripts/make-base-ami.sh),
# then publish it as a PUBLIC Community AMI and remove the previous public image.
# Usage: ./scripts/make-public-ami.sh [region] [version] [extra-region ...]
#   e.g. ./scripts/make-public-ami.sh ap-south-1 1.0.0 us-east-1
set -euo pipefail
REGION="${1:-ap-south-1}"; VERSION="${2:-$(date -u +%Y.%m.%d)}"; shift $(( $# > 2 ? 2 : $# )) || true
EXTRA_REGIONS=("$@")
cd "$(dirname "$0")/.."
ARCH=${ARCH:-amd64}; [ "$ARCH" = arm64 ] && AWSARCH=arm64 || AWSARCH=x86_64

need() { command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need packer

echo "==> Checking build network in $REGION"
bash scripts/ensure-build-network.sh "$REGION" >/dev/null

# 1) last image recorded in the repo (latest-images.json), if it still exists
BASE=$(jq -r --arg r "$REGION" --arg a "$ARCH" '.[$r][$a].ami // empty' latest-images.json 2>/dev/null || true)
if [ -n "$BASE" ] && ! aws ec2 describe-images --region "$REGION" --image-ids "$BASE" --query 'Images[0].State' --output text 2>/dev/null | grep -q available; then
  BASE=""
fi
# 2) otherwise the newest hardened image in the account
[ -n "$BASE" ] || BASE=$(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=cis-base,public Name=architecture,Values=$AWSARCH \
       --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
if [ "$BASE" = None ] || [ -z "$BASE" ]; then
  # 3) no image left: re-register one from the standalone backup snapshot (~1 min)
  BK=$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters Name=tag:Stage,Values=cis-base-backup Name=tag:Arch,Values="$ARCH" \
       Name=status,Values=completed --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)
  if [ -n "$BK" ] && [ "$BK" != None ]; then
    [ "$ARCH" = arm64 ] && BM=uefi || BM=uefi-preferred
    BASE=$(aws ec2 register-image --region "$REGION" --name "ubuntu-2404-cis-base-restored-$ARCH-$(date -u +%Y%m%d-%H%M)" \
           --description "PRIVATE hardened base restored from backup snapshot $BK" \
           --architecture "$AWSARCH" --root-device-name /dev/sda1 --virtualization-type hvm --ena-support \
           --boot-mode "$BM" --imds-support v2.0 \
           --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$BK,VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}" \
           --tag-specifications "ResourceType=image,Tags=[{Key=Stage,Value=cis-base}]" --query ImageId --output text)
    aws ec2 wait image-available --region "$REGION" --image-ids "$BASE"
    echo "==> Restored base $BASE from backup snapshot $BK"
  fi
fi
if [ "$BASE" = None ] || [ -z "$BASE" ]; then
  # 4) no image and no backup: build the base (one-time, ~25 min) for this architecture yet -> build the base first (one-time, ~25 min)
  echo "==> No hardened $ARCH image found - building the base first"
  ARCH=$ARCH bash scripts/make-base-ami.sh "$REGION"
  BASE=$(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=cis-base,public Name=architecture,Values=$AWSARCH \
         --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  FRESH=1   # the base was just built from scratch -> publish it directly, no second (quick) build
fi
echo "==> Quick build ($ARCH) in $REGION (v$VERSION) from base $BASE – about 10 min"
if [ "${FRESH:-0}" = 1 ]; then
  AMI=$BASE
else
  packer init quick.pkr.hcl
  packer build -color=false -var "region=$REGION" -var "version=$VERSION" -var "source_ami=$BASE" -var "arch=$ARCH" quick.pkr.hcl
  AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
fi
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

# record it in the repo: the next quick build starts from this image
NAME=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" --query 'Images[0].Name' --output text)
[ -f latest-images.json ] || echo '{}' > latest-images.json
jq --arg r "$REGION" --arg a "$ARCH" --arg ami "$AMI" --arg n "$NAME" --arg d "$(date -u +%Y-%m-%dT%H:%MZ)" \
   '.[$r][$a] = {ami:$ami, name:$n, built:$d}' latest-images.json > latest-images.json.tmp && mv latest-images.json.tmp latest-images.json

# keep only the newest public image in this region
for old in $(aws ec2 describe-images --region "$REGION" --owners self --filters Name=tag:Stage,Values=public Name=architecture,Values=$AWSARCH \
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
