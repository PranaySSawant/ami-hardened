#!/usr/bin/env bash
# Remove everything vulnerability scanners flag that the server does not need,
# keeping SSH. Runs after the CIS steps, before 99-marketplace-cleanup.sh.
#   - snapd            : Go binaries with bundled (old) Go stdlib/x-crypto
#   - ec2-instance-connect + curl : curl binary is flagged by upstream version
#   - cloud-init + its Python libraries (jinja2, jwt, oauthlib, requests, ...)
# cloud-init's job on EC2 (network, hostname, SSH key, user-data) is replaced by
# /usr/local/sbin/ec2-firstboot (shell + wget, IMDSv2 only).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Packages that must never be removed as a side effect
PROTECT="openssh-server openssh-client amazon-ssm-agent ufw unattended-upgrades apparmor
apparmor-utils auditd systemd systemd-timesyncd systemd-resolved lvm2 sudo libpam-pwquality
rsyslog netplan.io wget python3 python3-apt python3-yaml grub-pc grub-efi-amd64-signed grub-efi-arm64-signed grub-efi-arm64-bin
shim-signed linux-image-aws gdisk dosfstools tar"

# Keep every currently installed package: autoremove must not cascade
apt-mark manual $(apt-mark showauto) >/dev/null

WANT="snapd ec2-instance-connect curl cloud-init cloud-initramfs-copymods
python3-twisted python3-jwt python3-oauthlib python3-openssl python3-jinja2 python3-setuptools
python3-pkg-resources python3-urllib3 python3-requests python3-idna python3-certifi
python3-cryptography python3-pyasn1 python3-pyasn1-modules python3-httplib2 python3-pygments
python3-configobj python3-launchpadlib python3-lazr.restfulclient python3-lazr.uri
python3-wadllib python3-hamcrest python3-service-identity python3-automat
python3-constantly python3-hyperlink python3-incremental python3-zope.interface
python3-attr python3-bcrypt python3-markupsafe python3-blinker python3-jsonpatch
python3-jsonpointer python3-jsonschema python3-serial python3-requests-unixsocket"

# Only real (installed) packages, and only those whose removal doesn't touch PROTECT
SKIPPED=""
for p in $WANT; do
  dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || continue
  RM=$(apt-get -s purge "$p" | awk '/^Purg|^Remv/{print $2}')
  hit=""
  for k in $PROTECT; do grep -qx "$k" <<<"$RM" && hit="$k"; done
  if [ -n "$hit" ]; then SKIPPED="$SKIPPED $p(needed-by:$hit)"; continue; fi
  apt-get purge -y "$p"
done
echo "SLIM: kept because needed:${SKIPPED:- none}"

rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /etc/cloud /var/lib/cloud /var/log/cloud-init*

# squashfs only served snaps -> now disable it (CIS 1.1.1.7)
# (same files the CIS role uses for the other modules, so audit tools find it)
grep -q '^install squashfs' /etc/modprobe.d/CIS.conf 2>/dev/null || echo 'install squashfs /bin/false' >> /etc/modprobe.d/CIS.conf
grep -q '^blacklist squashfs' /etc/modprobe.d/blacklist.conf 2>/dev/null || echo 'blacklist squashfs' >> /etc/modprobe.d/blacklist.conf

# --- Network without cloud-init: DHCP on every ENA/virtio NIC ---
rm -f /etc/netplan/*.yaml
cat > /etc/netplan/50-ec2-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    ec2-nics:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
      optional: true
EOF
chmod 600 /etc/netplan/50-ec2-dhcp.yaml
netplan generate

# --- First-boot replacement for cloud-init ---
cat > /usr/local/sbin/ec2-firstboot <<'EOF'
#!/bin/bash
# Replaces cloud-init on this image: host keys, hostname, SSH key, user-data (#! scripts).
set -u
IMDS=http://169.254.169.254/latest
for i in $(seq 1 30); do
  TOK=$(wget -qO- --method=PUT --header='X-aws-ec2-metadata-token-ttl-seconds: 600' $IMDS/api/token) && break
  sleep 2
done
[ -n "${TOK:-}" ] || { echo "IMDS not reachable"; exit 0; }
get() { wget -qO- --header="X-aws-ec2-metadata-token: $TOK" "$IMDS/$1"; }

# SSH host keys (removed from the image)
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A

# Hostname from EC2 (ip-10-0-0-5 style)
H=$(get meta-data/local-hostname); H=${H%%.*}
if [ -n "$H" ]; then
  hostnamectl set-hostname "$H"
  grep -q "^127.0.1.1 " /etc/hosts && sed -i "s/^127.0.1.1 .*/127.0.1.1 $H/" /etc/hosts || echo "127.0.1.1 $H" >> /etc/hosts
fi

# Launch key pair -> ubuntu's authorized_keys (every boot, like cloud-init)
KEYS=""
for idx in $(get meta-data/public-keys/ 2>/dev/null | cut -d= -f1); do
  K=$(get "meta-data/public-keys/$idx/openssh-key") && KEYS+="$K"$'\n'
done
if [ -n "$KEYS" ]; then
  install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
  printf '%s' "$KEYS" > /home/ubuntu/.ssh/authorized_keys
  chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys; chmod 600 /home/ubuntu/.ssh/authorized_keys
fi

# User data: shell scripts (#!...) run once per instance, as root
IID=$(get meta-data/instance-id); STATE=/var/lib/ec2-firstboot
install -d -m 700 $STATE
if [ -n "$IID" ] && [ ! -e "$STATE/$IID" ]; then
  if get user-data > $STATE/user-data 2>/dev/null && head -c2 $STATE/user-data | grep -q '^#!'; then
    # run via its own interpreter (works even where /var is noexec)
    INTERP=$(head -1 $STATE/user-data | cut -c3- | xargs)
    $INTERP $STATE/user-data > /var/log/ec2-user-data.log 2>&1 || echo "user-data exited $?" >> /var/log/ec2-user-data.log
  fi
  rm -f $STATE/user-data; touch "$STATE/$IID"
fi
EOF
chmod 755 /usr/local/sbin/ec2-firstboot

cat > /etc/systemd/system/ec2-firstboot.service <<'EOF'
[Unit]
Description=EC2 first boot: host keys, hostname, SSH key, user-data (cloud-init replacement)
Wants=network-online.target
After=network-online.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ec2-firstboot
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ec2-firstboot.service
systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true

# Final check: nothing important went missing
for k in openssh-server amazon-ssm-agent ufw unattended-upgrades auditd netplan.io wget; do
  dpkg-query -W -f='${db:Status-Abbrev}' "$k" | grep -q '^[ih]i' || { echo "MISSING $k"; exit 1; }   # hi = installed + held
done
dpkg-query -W -f='${Package}\n' 'python3-*' | sort | paste -sd' '
