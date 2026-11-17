#!/usr/bin/env bash
# Extra CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 (L1+L2) settings applied
# after the ansible-lockdown role, so common compliance scanners report them correctly.
# Control refs = CIS recommendation numbers.
set -euxo pipefail

# ---------- SSH (CIS 5.1.x) ----------
# First value wins in sshd -> 00- prefix beats cloud-init / role drop-ins.
getent group sshusers >/dev/null || groupadd -r sshusers
usermod -aG sshusers ubuntu

cat > /etc/ssh/sshd_config.d/00-cis-hardening.conf <<'EOF'
# CIS Ubuntu 24.04 v1.0.0 – sshd (5.1.x)
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
# 5.1.6: no CBC, no chacha20-poly1305
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
# 5.1.12: no *-sha1 kex
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
# 5.1.15: no md5/ripemd/96-bit/umac-64
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
# 5.1.4: AllowGroups/DenyUsers/DenyGroups (AllowUsers not set – would block user-created accounts)
AllowGroups sshusers sudo
DenyUsers root
DenyGroups nossh
EOF
chmod 600 /etc/ssh/sshd_config.d/00-cis-hardening.conf
chown root:root /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*
chmod 600 /etc/ssh/sshd_config
sshd -t

# ---------- /tmp and /dev/shm (CIS 1.1.2.1.x, 1.1.2.2.x) ----------
# /tmp as tmpfs via fstab (CIS 1.1.2.1.1-4); remove any tmp.mount unit to avoid conflicts
systemctl disable tmp.mount 2>/dev/null || true
rm -f /etc/systemd/system/tmp.mount
sed -i -E '\#^\S+\s+/tmp\s#d' /etc/fstab
echo 'tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime,size=50%,mode=1777 0 0' >> /etc/fstab

grep -qE '^\S+\s+/dev/shm\s' /etc/fstab || \
  echo 'tmpfs /dev/shm tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0' >> /etc/fstab

# ---------- sshd -T must work before first SSH login (scanners rely on it) ----------
# Ubuntu 24.04 socket-activates ssh, so /run/sshd only exists after first connection.
echo 'd /run/sshd 0755 root root -' > /etc/tmpfiles.d/sshd-privsep.conf

# ---------- AppArmor: all profiles enforcing (CIS 1.3.1.4) – build time + every boot ----------
cat > /usr/local/sbin/cis-apparmor-enforce <<'AA'
#!/bin/sh
# Put every loaded profile that is in complain mode into enforce mode
aa-status --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("\n".join(k for k,v in d.get("profiles",{}).items() if v=="complain"))' | while IFS= read -r name; do
  [ -n "$name" ] || continue
  f=$(grep -rlsF -- "$name" /etc/apparmor.d /var/lib/snapd/apparmor/profiles 2>/dev/null | grep -v '/abstractions/\|/tunables/' | head -1)
  [ -n "$f" ] && aa-enforce "$f" >/dev/null 2>&1 || true
done
for f in $(grep -lsE 'flags=\([^)]*complain' /etc/apparmor.d/* 2>/dev/null); do aa-enforce "$f" >/dev/null 2>&1 || true; done
exit 0
AA
chmod 0750 /usr/local/sbin/cis-apparmor-enforce
cat > /etc/systemd/system/cis-apparmor-enforce.service <<'U'
[Unit]
Description=Enforce all AppArmor profiles (CIS 1.3.1.4)
After=apparmor.service snapd.apparmor.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cis-apparmor-enforce
[Install]
WantedBy=multi-user.target
U
systemctl enable cis-apparmor-enforce.service
/usr/local/sbin/cis-apparmor-enforce

# ---------- Core dumps (CIS 1.5.3) ----------
mkdir -p /etc/systemd
if [ -f /etc/systemd/coredump.conf ]; then
  sed -i -E '/^#?\s*(Storage|ProcessSizeMax)=/d' /etc/systemd/coredump.conf
  grep -q '^\[Coredump\]' /etc/systemd/coredump.conf || echo '[Coredump]' >> /etc/systemd/coredump.conf
  sed -i '/^\[Coredump\]/a Storage=none\nProcessSizeMax=0' /etc/systemd/coredump.conf
else
  printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf
fi
grep -qE '^\*\s+hard\s+core\s+0' /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null || \
  echo '* hard core 0' > /etc/security/limits.d/99-cis-core.conf

# ---------- at restricted to authorized users (CIS 2.4.2.1) ----------
rm -f /etc/at.deny
touch /etc/at.allow && chown root:root /etc/at.allow && chmod 0640 /etc/at.allow

# ---------- No LLMNR/mDNS listeners (fewer open ports, CIS 4.2.6) ----------
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/90-cis.conf

# ---------- Log file permissions, kept correct after boot (CIS 6.1.4.1) ----------
cat > /usr/local/sbin/cis-logperms <<'LP'
#!/bin/sh
find -L /var/log -type f ! -path '/var/log/apt/*' \
  ! \( -name 'lastlog*' -o -name 'wtmp*' -o -name 'btmp*' -o -name 'cloud-init.log*' -o -name 'localmessages*' -o -name '*.journal' -o -name '*.journal~' -o -name README \) \
  -perm /0137 -exec chmod u-x,g-wx,o-rwx {} + 2>/dev/null
find -L /var/log/apt -type f -perm /0133 -exec chmod u-x,go-wx {} + 2>/dev/null
exit 0
LP
chmod 0750 /usr/local/sbin/cis-logperms
cat > /etc/systemd/system/cis-logperms.service <<'U'
[Unit]
Description=Enforce CIS log file permissions
After=cloud-final.service amazon-ssm-agent.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cis-logperms
[Install]
WantedBy=multi-user.target
U
cat > /etc/systemd/system/cis-logperms.timer <<'U'
[Unit]
Description=Enforce CIS log file permissions (boot + hourly)
[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
U
systemctl enable cis-logperms.timer cis-logperms.service

# ---------- sysctl (CIS 1.5.x, 3.3.x) ----------
# Written to BOTH sysctl.d and the IPT_SYSCTL file referenced in /etc/default/ufw (ufw re-applies it)
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

# ---------- Shell timeout / umask (CIS 5.4.3.x) ----------
cat > /etc/profile.d/99-cis.sh <<'EOF'
umask 027
TMOUT=900
readonly TMOUT
export TMOUT
EOF
chmod 644 /etc/profile.d/99-cis.sh
sed -ri 's/^\s*UMASK\s+.*/UMASK 027/' /etc/login.defs

# ---------- Single firewall utility (CIS 4.1.1) ----------
systemctl disable --now nftables 2>/dev/null || true
systemctl mask nftables 2>/dev/null || true
apt-get purge -y iptables-persistent 2>/dev/null || true
ufw allow in 68/udp comment 'DHCP client'
ufw --force enable
