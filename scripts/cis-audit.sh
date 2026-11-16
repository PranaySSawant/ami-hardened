#!/usr/bin/env bash
# Score the latest public AMI against CIS Ubuntu 24.04 v1.0.0 (L1+L2) using the
# ansible-lockdown goss audit. Launches a temporary instance (SSM only, no SSH),
# runs the audit, prints the score + failed controls, then terminates the instance.
# Usage (CloudShell): bash scripts/cis-audit.sh [ami-id] [region]
set -euo pipefail
REGION="${2:-ap-south-1}"
AMI="${1:-$(aws ec2 describe-images --region "$REGION" --owners self \
  --filters "Name=name,Values=ubuntu-2404-cis-l2-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)}"
ROLE=cis-audit-ssm
echo "==> Auditing $AMI in $REGION"

# 1. SSM instance role (one-time)
if ! aws iam get-instance-profile --instance-profile-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name $ROLE >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name $ROLE --role-name $ROLE
  sleep 15
fi

# 2. Launch in the packer-build subnet (no inbound rules needed for SSM)
SUBNET=$(aws ec2 describe-subnets --region "$REGION" --filters Name=tag:Name,Values=packer-build \
  --query 'Subnets[0].SubnetId' --output text)
IID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type t3.small \
  --subnet-id "$SUBNET" --iam-instance-profile Name=$ROLE \
  --metadata-options HttpTokens=required \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cis-audit-temp}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "==> Instance $IID"
trap 'echo "==> Terminating $IID"; aws ec2 terminate-instances --region "$REGION" --instance-ids "$IID" >/dev/null' EXIT

echo "==> Waiting for SSM agent..."
for i in $(seq 1 60); do
  [ "$(aws ssm describe-instance-information --region "$REGION" \
      --filters Key=InstanceIds,Values="$IID" --query 'length(InstanceInformationList)' --output text)" = "1" ] && break
  sleep 10
done

# 3. Run the audit on the instance
CMD=$(cat <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q git >/dev/null
curl -sL https://github.com/goss-org/goss/releases/latest/download/goss-linux-amd64 -o /usr/local/bin/goss
chmod 755 /usr/local/bin/goss
rm -rf /opt/cis-audit
git clone -q -b benchmark_v1.0.0 --depth 1 https://github.com/ansible-lockdown/UBUNTU24-CIS-Audit.git /opt/cis-audit
cd /opt/cis-audit
/usr/local/bin/goss --version
/usr/local/bin/goss -g goss.yml --vars vars/CIS.yml v --max-concurrent 20 -f json > /var/tmp/cis.json 2>/var/tmp/cis.err || true
echo "json bytes: $(wc -c </var/tmp/cis.json)"; tail -15 /var/tmp/cis.err
python3 - <<'PY'
import json,re,collections
d=json.load(open('/var/tmp/cis.json'))
fails=collections.OrderedDict()
ctrl_all,ctrl_fail=set(),set()
for r in d['results']:
    t=(r.get('meta') or {}).get('title') or r.get('title') or ''
    m=re.match(r'\s*([0-9]+(?:\.[0-9]+)+)',t)
    cid=m.group(1) if m else t[:40]
    ctrl_all.add(cid)
    if not r.get('successful'):
        ctrl_fail.add(cid); fails.setdefault(cid,t.strip()[:90])
s=d['summary']
print(f"GOSS TESTS : {s['test-count']-s['failed-count']}/{s['test-count']} passed")
p=len(ctrl_all)-len(ctrl_fail)
print(f"CIS CONTROLS: {p}/{len(ctrl_all)} passed ({100*p//max(1,len(ctrl_all))}%), {len(ctrl_fail)} failed")
print("FAILED CONTROLS:")
for k in sorted(fails,key=lambda x:[int(n) if n.isdigit() else 0 for n in x.split('.')]):
    print(" ",fails[k])
PY
EOF
)
CID=$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript --timeout-seconds 1800 \
  --parameters "$(jq -n --arg c "$CMD" '{commands:[$c]}')" \
  --query Command.CommandId --output text)
echo "==> Running audit (2-5 min)..."
for i in $(seq 1 90); do
  ST=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
       --query Status --output text 2>/dev/null || echo Pending)
  case "$ST" in Success|Failed|TimedOut|Cancelled) break;; esac
  sleep 10
done
echo "==> Status: $ST"
aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
  --query StandardOutputContent --output text
aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
  --query StandardErrorContent --output text | tail -5
