#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Wait for cloud-init / unattended-upgrades to release apt locks
cloud-init status --wait || true
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done

apt-get update -y
apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -y
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = arm64 ]; then GRUBPKGS="grub-efi-arm64-bin grub-efi-arm64-signed shim-signed"; else GRUBPKGS="grub-pc-bin grub-efi-amd64-bin"; fi
apt-get install -y python3 python3-apt acl unattended-upgrades amazon-ec2-utils wget lvm2 gdisk dosfstools $GRUBPKGS

# SSM agent: use the official .deb instead of the snap. The snap runs under AppArmor
# *complain* profiles (snap.amazon-ssm-agent.*), which fails CIS 1.3.1.4.
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
REG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
curl -fsSL -o /tmp/amazon-ssm-agent.deb \
  "https://s3.${REG}.amazonaws.com/amazon-ssm-${REG}/latest/debian_${ARCH}/amazon-ssm-agent.deb" || \
curl -fsSL -o /tmp/amazon-ssm-agent.deb \
  "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_${ARCH}/amazon-ssm-agent.deb"
snap remove --purge amazon-ssm-agent 2>/dev/null || true
dpkg -i /tmp/amazon-ssm-agent.deb
rm -f /tmp/amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent

# Time sync (CIS 2.3.1.1): only ONE of timesyncd/chrony. Use timesyncd -> Amazon Time Sync.
# AWS Ubuntu images ship chrony (conflicts with timesyncd) – installing timesyncd removes it
apt-get install -y systemd-timesyncd
apt-get purge -y chrony 2>/dev/null || true
systemctl unmask systemd-timesyncd
systemctl enable --now systemd-timesyncd

apt-get autoremove -y --purge
