#!/usr/bin/env bash
# CIS 1.1.2.3 – 1.1.2.7: separate partitions for /home, /var, /var/tmp, /var/log, /var/log/audit.
# Runs AFTER the cleanup step: copies the (already cleaned) data onto the extra EBS volumes
# attached by Packer (/dev/sdf..sdj) and mounts them by LABEL from /etc/fstab on next boot.
set -euxo pipefail

# Resolve an EBS device name (sdf) to its NVMe/xen block device
dev_for() {
  local name=$1 d
  [ -e "/dev/$name" ] && { readlink -f "/dev/$name"; return; }
  [ -e "/dev/xvd${name#sd}" ] && { readlink -f "/dev/xvd${name#sd}"; return; }
  for d in /dev/nvme*n1; do
    if ebsnvme-id -b "$d" 2>/dev/null | grep -qE "^(/dev/)?(${name}|xvd${name#sd})$"; then echo "$d"; return; fi
  done
  echo "ERROR: no block device for $name" >&2; exit 1
}

#           ebs-name  label            mountpoint       options
MOUNTS=$(cat <<'EOF'
sdf CIS_VAR      /var           defaults,nodev,nosuid
sdg CIS_VARLOG   /var/log       defaults,nodev,nosuid,noexec
sdh CIS_AUDIT    /var/log/audit defaults,nodev,nosuid,noexec
sdi CIS_VARTMP   /var/tmp       defaults,nodev,nosuid,noexec
sdj CIS_HOME     /home          defaults,nodev,nosuid
EOF
)

STAGE=/mnt/cis
mkdir -p $STAGE

# 1. Format + stage-mount each volume
while read -r ebs label mp opts; do
  dev=$(dev_for "$ebs")
  mkfs.ext4 -q -F -L "$label" "$dev"
  mkdir -p "$STAGE/$label"
  mount "$dev" "$STAGE/$label"
done <<<"$MOUNTS"

# 2. Copy data (nested mounts excluded; their mountpoints recreated empty)
command -v rsync >/dev/null || apt-get install -y -q rsync
RS="rsync -aAXH --numeric-ids"
$RS --exclude=/log/ --exclude=/tmp/ /var/   $STAGE/CIS_VAR/
install -d -m 0755 -o root -g syslog $STAGE/CIS_VAR/log 2>/dev/null || install -d -m 0755 $STAGE/CIS_VAR/log
install -d -m 1777 -o root -g root   $STAGE/CIS_VAR/tmp
$RS --exclude=/audit/ /var/log/              $STAGE/CIS_VARLOG/
install -d -m 0750 -o root -g root   $STAGE/CIS_VARLOG/audit
$RS /var/log/audit/                          $STAGE/CIS_AUDIT/
$RS /var/tmp/                                $STAGE/CIS_VARTMP/
chmod 1777 $STAGE/CIS_VARTMP
$RS /home/                                   $STAGE/CIS_HOME/

# 3. fstab entries (by LABEL – stable across instance types / NVMe ordering)
sed -i -E '/LABEL=CIS_(VAR|VARLOG|AUDIT|VARTMP|HOME)\s/d' /etc/fstab
while read -r ebs label mp opts; do
  echo "LABEL=$label  $mp  ext4  $opts,x-systemd.device-timeout=30s  0 2" >> /etc/fstab
done <<<"$MOUNTS"

# 4. Unmount staging; volumes are captured in the AMI with the data
sync
for l in CIS_HOME CIS_VARTMP CIS_AUDIT CIS_VARLOG CIS_VAR; do umount "$STAGE/$l"; done
rmdir $STAGE/* $STAGE
findmnt --verify --tab-file /etc/fstab || true
cat /etc/fstab
