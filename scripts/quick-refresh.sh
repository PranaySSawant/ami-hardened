#!/usr/bin/env bash
# Quick build step: newest Ubuntu security updates on top of the hardened base image.
# OpenSSH (upstream build) and SSM Agent (latest-Go build) are kept from the base image;
# the monthly base build refreshes them.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -o Dpkg::Options::=--force-confold upgrade      # held OpenSSH packages are skipped
apt-get -y autoremove --purge
# sanity checks - fail the build rather than publish a broken image
ssh -V 2>&1 | grep -q '^OpenSSH_10\.' || { echo "upstream OpenSSH missing"; exit 1; }
/usr/sbin/sshd -t
systemctl is-active ssh.service
systemctl is-active amazon-ssm-agent
grep -a -q -E 'go1\.(2[7-9]|[3-9][0-9])' /usr/bin/amazon-ssm-agent || { echo "SSM Agent not built with latest Go"; exit 1; }
for p in snapd cloud-init curl ec2-instance-connect; do
  ! dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || { echo "$p came back"; exit 1; }
done
echo "QUICK-REFRESH OK: $(ssh -V 2>&1)"
