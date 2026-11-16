#!/usr/bin/env bash
# Closes gaps between ansible-lockdown output and the Qualys
# "CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 (L1+L2)" policy checks.
# Control refs = Qualys policy sequence / CID.
set -euxo pipefail

# ---------- SSH (5.2–5.29) ----------
# First value wins in sshd -> 00- prefix beats cloud-init / role drop-ins.
getent group sshusers >/dev/null || groupadd -r sshusers
usermod -aG sshusers ubuntu

cat > /etc/ssh/sshd_config.d/00-cis-hardening.conf <<'EOF'
# CIS Ubuntu 24.04 v1.0.0 – sshd (Qualys 5.6–5.29)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
UsePAM yes
GSSAPIAuthentication no
DisableForwarding yes
LogLevel VERBOSE
LoginGraceTime 60
MaxAuthTries 4
MaxSessions 10
MaxStartups 10:30:60
ClientAliveInterval 15
ClientAliveCountMax 3
Banner /etc/issue.net
# 26778: no CBC, no chacha20-poly1305
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
# 26780: no *-sha1 kex
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
# 29616: no md5/ripemd/96-bit/umac-64
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
# 26879/26881/26882 (AllowUsers 26880 intentionally not set – would block buyer-created users)
AllowGroups sshusers sudo
DenyUsers root
DenyGroups nossh
EOF
chmod 600 /etc/ssh/sshd_config.d/00-cis-hardening.conf
chown root:root /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*
chmod 600 /etc/ssh/sshd_config
sshd -t

# ---------- /tmp and /dev/shm (1.31–1.39) ----------
cat > /etc/systemd/system/tmp.mount <<'EOF'
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,noexec,size=50%

[Install]
WantedBy=local-fs.target
EOF
systemctl daemon-reload
systemctl unmask tmp.mount
systemctl enable tmp.mount          # active from first boot

grep -qE '^\S+\s+/dev/shm\s' /etc/fstab || \
  echo 'tmpfs /dev/shm tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0' >> /etc/fstab

# ---------- sysctl (1.75–1.81, 3.24–3.83) ----------
# Qualys checks BOTH sysctl.d and the IPT_SYSCTL file referenced in /etc/default/ufw
read -r -d '' CIS_SYSCTL <<'EOF' || true
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF
printf '%s\n' "$CIS_SYSCTL" > /etc/sysctl.d/60-cis.conf
chmod 644 /etc/sysctl.d/60-cis.conf

UFW_SYSCTL=$(sed -nE 's/^IPT_SYSCTL=(.*)/\1/p' /etc/default/ufw | tr -d '"')
UFW_SYSCTL=${UFW_SYSCTL:-/etc/ufw/sysctl.conf}
# drop any conflicting slash/dot-form keys, then append CIS values
for key in $(printf '%s\n' "$CIS_SYSCTL" | awk '{print $1}'); do
  slash=${key//./\/}
  sed -i -E "\#^\s*(${key//./\\.}|${slash})\s*=#d" "$UFW_SYSCTL"
done
printf '\n# CIS Ubuntu 24.04 v1.0.0\n%s\n' "$CIS_SYSCTL" >> "$UFW_SYSCTL"
sysctl --system >/dev/null

# ---------- Shell timeout / umask (5.112, 5.113) ----------
cat > /etc/profile.d/99-cis.sh <<'EOF'
umask 027
TMOUT=900
readonly TMOUT
export TMOUT
EOF
chmod 644 /etc/profile.d/99-cis.sh
sed -ri 's/^\s*UMASK\s+.*/UMASK 027/' /etc/login.defs

# ---------- Single firewall (4.18, 4.28, 4.29) ----------
systemctl disable --now nftables 2>/dev/null || true
systemctl mask nftables 2>/dev/null || true
apt-get purge -y iptables-persistent 2>/dev/null || true
ufw --force enable
