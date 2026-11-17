#!/usr/bin/env bash
# One-time setup in YOUR AWS account (run from CloudShell or a laptop with admin creds).
# Creates: Marketplace AMI ingestion role + GitHub Actions OIDC role for automated releases.
# Usage: ./bootstrap/setup-aws.sh <github-user>/<repo>
set -euo pipefail
REPO="${1:?usage: $0 <github-user>/<repo>}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. Marketplace ingestion role
aws iam create-role --role-name AWSMarketplaceAmiIngestion \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"assets.marketplace.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  >/dev/null 2>&1 || echo "ingestion role exists"
aws iam attach-role-policy --role-name AWSMarketplaceAmiIngestion \
  --policy-arn arn:aws:iam::aws:policy/AWSMarketplaceAmiIngestion

# 2. GitHub OIDC provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  >/dev/null 2>&1 || echo "OIDC provider exists"

# 3. Role GitHub Actions assumes (only from main branch of your repo)
cat > /tmp/gh-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
  "StringLike":{"token.actions.githubusercontent.com:sub":[
   "repo:${REPO}:ref:refs/heads/main","repo:${REPO,,}:ref:refs/heads/main",
   "repo:${REPO%%/*}@*/${REPO#*/}@*:ref:refs/heads/main"]}}}]}
EOF
aws iam create-role --role-name ami-release-github --max-session-duration 21600 \
  --assume-role-policy-document file:///tmp/gh-trust.json >/dev/null 2>&1 \
  || aws iam update-assume-role-policy --role-name ami-release-github --policy-document file:///tmp/gh-trust.json
aws iam update-role --role-name ami-release-github --max-session-duration 21600

cat > /tmp/gh-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"PackerEC2","Effect":"Allow","Action":[
   "ec2:Describe*","ec2:RunInstances","ec2:TerminateInstances","ec2:StopInstances",
   "ec2:CreateImage","ec2:RegisterImage","ec2:DeregisterImage","ec2:CreateSnapshot","ec2:DeleteSnapshot",
   "ec2:CreateTags","ec2:ModifyImageAttribute","ec2:ModifyInstanceAttribute",
   "ec2:CreateKeyPair","ec2:DeleteKeyPair","ec2:CreateSecurityGroup","ec2:DeleteSecurityGroup",
   "ec2:AuthorizeSecurityGroupIngress","ec2:GetPasswordData","ec2:CreateVolume","ec2:DeleteVolume",
   "ec2:AttachVolume","ec2:DetachVolume","ec2:CopyImage",
   "ec2:DisableImageBlockPublicAccess","ec2:GetImageBlockPublicAccessState",
   "ec2:CreateVpc","ec2:ModifyVpcAttribute","ec2:CreateSubnet","ec2:ModifySubnetAttribute",
   "ec2:CreateInternetGateway","ec2:AttachInternetGateway","ec2:CreateRoute","ec2:ReplaceRoute"],"Resource":"*"},
 {"Sid":"Marketplace","Effect":"Allow","Action":[
   "aws-marketplace:StartChangeSet","aws-marketplace:DescribeChangeSet",
   "aws-marketplace:DescribeEntity","aws-marketplace:ListChangeSets"],"Resource":"*"},
 {"Sid":"PassIngestionRole","Effect":"Allow","Action":"iam:PassRole",
  "Resource":"arn:aws:iam::${ACCOUNT_ID}:role/AWSMarketplaceAmiIngestion"}]}
EOF
aws iam put-role-policy --role-name ami-release-github --policy-name ami-release \
  --policy-document file:///tmp/gh-policy.json

# 4. Dedicated public build subnet (for accounts without a default VPC)
bash "$(dirname "$0")/../scripts/ensure-build-network.sh" "${BUILD_REGION:-ap-south-1}"

echo
echo "Add these as GitHub repo secrets (Settings → Secrets and variables → Actions):"
echo "  AWS_ROLE_ARN      = arn:aws:iam::${ACCOUNT_ID}:role/ami-release-github"
echo "  INGESTION_ROLE_ARN= arn:aws:iam::${ACCOUNT_ID}:role/AWSMarketplaceAmiIngestion"
echo "  PRODUCT_ID        = prod-xxxxxxxxxxxx   (after you create the product once in the portal)"
