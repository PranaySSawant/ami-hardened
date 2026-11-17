#!/usr/bin/env bash
# CIS 1.1.2.3 – 1.1.2.7: separate partitions for /home, /var, /var/tmp, /var/log, /var/log/audit.
# One 25 GB EBS data volume (/dev/sdf) is split with LVM into 5 logical volumes.
# Runs AFTER the cleanup step: copies the (already cleaned) data onto the LVs and mounts
# them from /etc/fstab on next boot. Users can grow any LV later:
#   resize EBS -> pvresize /dev/nvmeXn1 -> lvextend -r -L +5G /dev/cis/var
set -euxo pipefail

# Resolve the EBS device name sdf to its NVMe/xen block device
dev_for() {
  local name=$1 d
  [ -e "/dev/$name" ] && { readlink -f "/dev/$name"; return; }
  [ -e "/dev/xvd${name#sd}" ] && { readlink -f "/dev/xvd${name#sd}"; return; }
  for d in /dev/nvme*n1; do
    if ebsnvme-id -b "$d" 2>/dev/null | grep -qE "^(/dev/)?(${name}|xvd${name#sd})$"; then echo "$d"; return; fi
  done
  echo "ERROR: no block device for $name" >&2; exit 1
}

command -v rsync  >/dev/null || { echo "rsync missing (installed in 01-prep.sh)"; exit 1; }
command -v lvcreate >/dev/null || { echo "lvm2 missing (installed in 01-prep.sh)"; exit 1; }

DEV=$(dev_for sdf)
VG=cis

#  lv        size   label          mountpoint       options
LVS=$(cat <<'EOF'
var        10G    CIS_VAR        /var             defaults,nodev,nosuid
varlog      5G    CIS_VARLOG     /var/log         defaults,nodev,nosuid,noexec
audit       3G    CIS_AUDIT      /var/log/audit   defaults,nodev,nosuid,noexec
vartmp      2G    CIS_VARTMP     /var/tmp         defaults,nodev,nosuid,noexec
home        4G    CIS_HOME       /home            defaults,nodev,nosuid
EOF
)

# 1. LVM on the data volume
# EBS volumes get a new serial per instance -> never pin PVs by device ID
rm -f /etc/lvm/devices/system.devices
grep -q 'use_devicesfile' /etc/lvm/lvmlocal.conf 2>/dev/null || \
  printf '\ndevices {\n\tuse_devicesfile = 0\n}\n' >> /etc/lvm/lvmlocal.conf
wipefs -a "$DEV"
pvcreate -ff -y "$DEV"
vgcreate "$VG" "$DEV"
STAGE=/mnt/cis
mkdir -p $STAGE
while read -r lv size label mp opts; do
  lvcreate -y -L "$size" -n "$lv" "$VG"
  mkfs.ext4 -q -F -L "$label" "/dev/$VG/$lv"
  mkdir -p "$STAGE/$label"
  mount "/dev/$VG/$lv" "$STAGE/$label"
done <<<"$LVS"

# 2. Copy data (nested mounts excluded; their mountpoints recreated empty)
RS="rsync -aAXH --numeric-ids"
$RS --exclude=/log/ --exclude=/tmp/ /var/   $STAGE/CIS_VAR/
install -d -m 0775 -o root -g syslog $STAGE/CIS_VAR/log 2>/dev/null || install -d -m 0755 $STAGE/CIS_VAR/log
install -d -m 1777 -o root -g root   $STAGE/CIS_VAR/tmp
$RS --exclude=/audit/ /var/log/              $STAGE/CIS_VARLOG/
install -d -m 0750 -o root -g root   $STAGE/CIS_VARLOG/audit
$RS /var/log/audit/                          $STAGE/CIS_AUDIT/
$RS /var/tmp/                                $STAGE/CIS_VARTMP/
chmod 1777 $STAGE/CIS_VARTMP
$RS /home/                                   $STAGE/CIS_HOME/

# 3. fstab entries (LVM paths are stable across instance types / NVMe ordering)
sed -i -E '\#^/dev/(mapper/)?cis[-/]#d; /LABEL=CIS_(VAR|VARLOG|AUDIT|VARTMP|HOME)\s/d' /etc/fstab
while read -r lv size label mp opts; do
  # nofail + timeout: if the data volume is ever missing, boot continues on the root copy
  echo "/dev/mapper/${VG}-${lv}  $mp  ext4  $opts,nofail,x-systemd.device-timeout=30s  0 2" >> /etc/fstab
done <<<"$LVS"

# 4. Unmount staging + deactivate VG; volume is captured in the AMI with the data
sync
for l in CIS_HOME CIS_VARTMP CIS_AUDIT CIS_VARLOG CIS_VAR; do umount "$STAGE/$l"; done
rmdir $STAGE/* $STAGE
vgchange -an "$VG"
rm -f /etc/lvm/devices/system.devices
lvmconfig devices/use_devicesfile
findmnt --verify --tab-file /etc/fstab || true
grep -E 'cis-|/tmp|/dev/shm' /etc/fstab
