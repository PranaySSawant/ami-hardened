#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Wait for cloud-init / unattended-upgrades to release apt locks
cloud-init status --wait || true
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done

apt-get update -y
apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -y
apt-get install -y python3 python3-apt acl unattended-upgrades amazon-ec2-utils

# SSM agent (snap on Ubuntu AMIs) – keep, buyers expect it
snap list amazon-ssm-agent >/dev/null 2>&1 || snap install amazon-ssm-agent --classic

# Time sync (CIS 2.3.1.1): only ONE of timesyncd/chrony. Use timesyncd -> Amazon Time Sync.
# AWS Ubuntu images ship chrony (conflicts with timesyncd) – installing timesyncd removes it
apt-get install -y systemd-timesyncd
apt-get purge -y chrony 2>/dev/null || true
systemctl unmask systemd-timesyncd
systemctl enable --now systemd-timesyncd

apt-get autoremove -y --purge
