#!/usr/bin/env bash
# Build the hardened AMI and publish it as a PUBLIC Community AMI.
# Usage: ./scripts/make-public-ami.sh [region] [version] [extra-region ...]
#   e.g. ./scripts/make-public-ami.sh ap-south-1 1.0.0 us-east-1
set -euo pipefail
REGION="${1:-ap-south-1}"; VERSION="${2:-$(date -u +%Y.%m.%d)}"; shift $(( $# > 2 ? 2 : $# )) || true
EXTRA_REGIONS=("$@")
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need packer; need ansible-playbook

echo "==> Building in $REGION (v$VERSION) – takes ~30–60 min"
ansible-galaxy install -r ansible/requirements.yml -p ansible/roles --force
ansible-galaxy collection install community.general ansible.posix
packer init .
packer build -color=false -var "region=$REGION" -var "version=$VERSION" ubuntu2404-cis.pkr.hcl
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
