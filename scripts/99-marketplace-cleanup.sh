#!/usr/bin/env bash
# AWS Marketplace AMI hygiene – run as the LAST provisioner.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Verify effective SSH policy (set in 00-cis-hardening.conf) ---
sshd -t
sshd -T -C user=ubuntu,host=x,addr=127.0.0.1 | grep -qx 'permitrootlogin no'
sshd -T -C user=ubuntu,host=x,addr=127.0.0.1 | grep -qx 'passwordauthentication no'
sshd -T -C user=ubuntu,host=x,addr=127.0.0.1 | grep -q '^ciphers ' && \
  ! sshd -T -C user=ubuntu,host=x,addr=127.0.0.1 | grep -q 'chacha20'

# Lock root + any password on default user
passwd -l root
passwd -d ubuntu || true
passwd -l ubuntu || true

# --- Remove all credentials / keys ---
find / -xdev \( -name authorized_keys -o -name authorized_keys2 \) -type f -print -delete 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*            # regenerated on first boot
rm -rf /root/.ssh /root/.aws /home/*/.aws /home/*/.ansible /root/.ansible
rm -f /root/.bash_history /home/*/.bash_history /root/.viminfo /home/*/.viminfo
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# --- Package cache ---
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

# --- Logs ---
journalctl --rotate || true
journalctl --vacuum-time=1s || true
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.[0-9]" -delete
find /var/log -type f -exec truncate -s 0 {} \;

# --- Per-instance identity ---
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
cloud-init clean --logs --seed
rm -rf /var/lib/cloud/instances/*

# Ubuntu Pro / Landscape must not be attached in a resold AMI
command -v pro >/dev/null && pro detach --assume-yes || true

sync
history -c || true
