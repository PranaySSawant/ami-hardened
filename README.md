# Ubuntu 24.04 CIS L1+L2 – AWS Marketplace AMI

## Build
```bash
# prereqs on build host: packer >= 1.10, ansible-core >= 2.15, AWS creds
cd ubuntu2404-cis-ami
ansible-galaxy install -r ansible/requirements.yml -p ansible/roles
packer init .
packer validate .
packer build -var 'version=1.0.0' ubuntu2404-cis.pkr.hcl
# arm64:
packer build -var 'arch=arm64' -var 'instance_type=t4g.medium' ubuntu2404-cis.pkr.hcl
```
AMI ID -> `manifest.json`.

## Verify before submitting
```bash
# launch test instance from new AMI, then on it:
sudo apt-get install -y git ansible-core
git clone https://github.com/ansible-lockdown/UBUNTU24-CIS-Audit.git /opt/cis-audit
sudo /opt/cis-audit/run_audit.sh            # goss-based CIS report
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication'
sudo ufw status verbose
ls /root/.ssh /etc/ssh/ssh_host_* 2>&1      # host keys regenerated on boot = OK
```
Also run your Qualys / Inspector scan – Marketplace rejects AMIs with open critical/high CVEs.

## Marketplace ingestion role (one-time)
```bash
cat > trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"assets.marketplace.amazonaws.com"},
 "Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name AWSMarketplaceAmiIngestion \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name AWSMarketplaceAmiIngestion \
  --policy-arn arn:aws:iam::aws:policy/AWSMarketplaceAmiIngestion
```

## Submit
1. Marketplace Management Portal → **Assets → Amazon Machine Image → Scan AMI** (self-service scan; fix any findings).
2. **Products → Server → Create server product → Amazon Machine Image**.
3. Add version: AMI ID, ingestion role ARN, OS user `ubuntu`, OS = Ubuntu 24.04, scanning port 22,
   usage instructions, recommended instance type, security group (tcp/22).
4. Publish as Limited first → test launch from the Marketplace listing → request Public.

## Qualys compliance scan (policy: CIS Ubuntu 24.04 v1.0.0 L1+L2)
Launch a test instance from the AMI → install Qualys Cloud Agent (or authenticated scan) →
run the policy → expected failures should be ONLY the exceptions below.
Policy is locked; copy it and mark the exceptions to get a clean report for the listing.

## Documented exceptions (Qualys seq / CID → put in listing usage notes)
| Qualys | CIS | Reason |
|---|---|---|
| 1.40–1.57 (29044, 29055, 29058, 29062, 29066…) | 1.1.2.3–1.1.2.7 | Separate /home, /var, /var/tmp, /var/log, /var/log/audit partitions – single-root cloud image. Fixable later with extra EBS volumes baked into the AMI |
| 1.70 (13271) | 1.4.1 | GRUB password breaks EC2 serial console / unattended recovery |
| 5.6 (26880) | 5.1.4 | AllowUsers not set – AllowGroups/DenyUsers/DenyGroups used instead (CIS needs only one). Buyers add users to `sshusers` |
| 5.35 (29136) | 5.2.4 | `ubuntu` has no password (key-only), so cloud-init NOPASSWD sudo is required |
| 6.28/6.29 | 6.1.3.6 | Remote log host – buyer-specific |

## Buyer notes (put in usage instructions)
- SSH: key only, user `ubuntu`; new SSH users must be in group `sshusers` or `sudo`.
- /tmp and /dev/shm are `noexec`.
- IPv6 `accept_ra=0` + strict `rp_filter=1`: for dual-stack or multi-ENI instances, relax in `/etc/sysctl.d/60-cis.conf` and `/etc/ufw/sysctl.conf`.
- ufw default deny inbound; only 22/tcp open.
