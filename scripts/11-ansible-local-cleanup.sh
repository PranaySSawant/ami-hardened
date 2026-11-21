#!/usr/bin/env bash
# Remove the build-time Ansible again (nothing of it stays in the image)
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /opt/cis-ansible /root/.ansible /tmp/packer-provisioner-ansible-local*
apt-get purge -y -q python3-venv 'python3.*-venv' python3-pip-whl python3-setuptools-whl 2>/dev/null || true
apt-get autoremove -y -q --purge
