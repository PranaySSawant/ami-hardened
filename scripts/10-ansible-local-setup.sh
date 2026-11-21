#!/usr/bin/env bash
# Build-time only: a throw-away Ansible in /opt/cis-ansible so the CIS role runs LOCALLY on the
# build server (no SSH round-trip per task: ~19 min -> ~5 min). Removed again after the role ran.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q python3-venv
python3 -m venv /opt/cis-ansible
/opt/cis-ansible/bin/pip install -q 'ansible-core>=2.17,<2.19'
/opt/cis-ansible/bin/ansible-galaxy collection install -p /root/.ansible/collections community.general ansible.posix
/opt/cis-ansible/bin/ansible-playbook --version | head -1
