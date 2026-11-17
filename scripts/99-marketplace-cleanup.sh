#!/usr/bin/env bash
# AWS Marketplace AMI hygiene – run as the LAST provisioner.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Verify effective SSH policy (set in 00-cis-hardening.conf) ---
sshd -t
SSHD_EFF=$(sshd -T -C user=ubuntu,host=x,addr=127.0.0.1)   # capture first: grep -q + pipefail = SIGPIPE false failure
grep -qx 'permitrootlogin no'        <<<"$SSHD_EFF"
grep -qx 'passwordauthentication no' <<<"$SSHD_EFF"
grep -q  '^ciphers '                 <<<"$SSHD_EFF"
! grep -q 'chacha20'                 <<<"$SSHD_EFF"
echo "SSH policy verified"

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
# Remove every kernel except the running (newest, patched) one. Old kernels left
# behind by dist-upgrade are flagged by vulnerability scanners (Inspector etc.)
RUNK=$(uname -r); RUNV=${RUNK%-aws}
NEWEST=$(ls /boot/vmlinuz-[0-9]* | sed 's#.*/vmlinuz-##' | sort -V | tail -1)
[ "$NEWEST" = "$RUNK" ] || { echo "running $RUNK is not the newest kernel ($NEWEST) - keeping all kernels"; RUNV=KEEPALL; }
OLD=$(dpkg-query -W -f='${db:Status-Abbrev}${Package}\n' 'linux-image-[0-9]*' 'linux-modules-[0-9]*' \
        'linux-modules-extra-[0-9]*' 'linux-headers-[0-9]*' 'linux-aws-headers-[0-9]*' \
        'linux-aws-*-headers-[0-9]*' 'linux-tools-[0-9]*' 'linux-aws-*-tools-[0-9]*' 2>/dev/null \
      | awk '/^ii /{print $2}' | grep -v -- "$RUNV" || true)
[ "$RUNV" = KEEPALL ] && OLD=
[ -n "$OLD" ] && DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD
dpkg -l | awk '/^ii +linux-(image|modules)-[0-9]/{print $2}'
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

# --- Logs ---
journalctl --rotate || true
journalctl --vacuum-time=1s || true
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.[0-9]" -delete
find /var/log -type f -exec truncate -s 0 {} \;
/usr/local/sbin/cis-logperms

# --- Per-instance identity ---
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
cloud-init clean --logs --seed
rm -rf /var/lib/cloud/instances/*

# Ubuntu Pro / Landscape must not be attached in a resold AMI
command -v pro >/dev/null && pro detach --assume-yes || true

sync
history -c || true
