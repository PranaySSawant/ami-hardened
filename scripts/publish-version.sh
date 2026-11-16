#!/usr/bin/env bash
# Adds a new AMI version to an existing Marketplace product via the Catalog API.
# Usage: publish-version.sh <ami-id> <version> [VALIDATE|APPLY]
# Env:   PRODUCT_ID, INGESTION_ROLE_ARN
set -euo pipefail
AMI_ID="${1:?ami id}"; VERSION="${2:?version}"; INTENT="${3:-APPLY}"
: "${PRODUCT_ID:?set PRODUCT_ID}"; : "${INGESTION_ROLE_ARN:?set INGESTION_ROLE_ARN}"

USAGE=$(cat <<'EOF'
1. Launch with your EC2 key pair; SSH as 'ubuntu' (key-only, root login disabled).
2. Security group: allow 22/tcp from your IP. ufw allows only 22/tcp inbound.
3. New SSH users must be in group 'sshusers' or 'sudo'.
4. /tmp and /dev/shm are noexec. IMDSv2 required. SSM agent pre-installed.
5. For dual-stack IPv6 or multi-ENI, relax accept_ra / rp_filter in /etc/sysctl.d/60-cis.conf and /etc/ufw/sysctl.conf.
EOF
)

DETAILS=$(jq -n \
  --arg ami "$AMI_ID" --arg role "$INGESTION_ROLE_ARN" --arg ver "$VERSION" --arg usage "$USAGE" \
  '{
    Version: { VersionTitle: $ver, ReleaseNotes: ("Monthly security patch release " + $ver) },
    DeliveryOptions: [{
      Details: { AmiDeliveryOptionDetails: {
        AmiSource: {
          AmiId: $ami, AccessRoleArn: $role, UserName: "ubuntu",
          OperatingSystemName: "UBUNTU", OperatingSystemVersion: "24.04 LTS", ScanningPort: 22
        },
        UsageInstructions: $usage,
        RecommendedInstanceType: "t3.medium",
        SecurityGroups: [{ IpProtocol: "tcp", FromPort: 22, ToPort: 22, IpRanges: ["0.0.0.0/0"] }]
      }}
    }]
  }')

CHANGESET=$(jq -n --arg pid "$PRODUCT_ID" --arg d "$DETAILS" \
  '[{ChangeType:"AddDeliveryOptions", Entity:{Type:"AmiProduct@1.0", Identifier:$pid}, Details:$d}]')

CS_ID=$(aws marketplace-catalog start-change-set --region us-east-1 \
  --catalog AWSMarketplace --intent "$INTENT" \
  --change-set-name "add-version-${VERSION}" \
  --change-set "$CHANGESET" --query ChangeSetId --output text)
echo "ChangeSet: $CS_ID"

# Wait (AMI scan + ingestion can take 1–3 h)
for i in $(seq 1 120); do
  STATUS=$(aws marketplace-catalog describe-change-set --region us-east-1 \
    --catalog AWSMarketplace --change-set-id "$CS_ID" --query Status --output text)
  echo "$(date -u +%H:%M) $STATUS"
  case "$STATUS" in
    SUCCEEDED) exit 0 ;;
    FAILED|CANCELLED)
      aws marketplace-catalog describe-change-set --region us-east-1 \
        --catalog AWSMarketplace --change-set-id "$CS_ID" \
        --query 'ChangeSet[].ErrorDetailList' --output json
      exit 1 ;;
  esac
  sleep 120
done
echo "Still running – check AWS Marketplace Management Portal → Requests"; exit 0
