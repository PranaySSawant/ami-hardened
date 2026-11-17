#!/usr/bin/env bash
# Build the AMI's single 30 GB root disk with separate CIS partitions
# (CIS 1.1.2.3 – 1.1.2.7: /home, /var, /var/tmp, /var/log, /var/log/audit).
#
# Runs LAST, after hardening + cleanup. Copies the running (hardened, cleaned) system
# from the builder disk onto the target disk /dev/sdf, installs GRUB for UEFI + BIOS.
# Packer (amazon-ebssurrogate) then registers /dev/sdf as the AMI root.
#
# Layout (GPT, 30 GiB):
#   p14  4 MiB    BIOS boot (legacy GRUB)
#   p15  106 MiB  EFI System Partition (vfat, /boot/efi)
#   p1   10 GiB   /          ext4
#   p2   rest     LVM PV  -> VG "cis":
#                   var 8G  varlog 4G  audit 2G  vartmp 2G  home 3G  (+ ~0.8G free)
set -euxo pipefail

dev_for() {
  local name=$1 d
  [ -e "/dev/$name" ] && { readlink -f "/dev/$name"; return; }
  [ -e "/dev/xvd${name#sd}" ] && { readlink -f "/dev/xvd${name#sd}"; return; }
  for d in /dev/nvme*n1; do
    if ebsnvme-id -b "$d" 2>/dev/null | grep -qE "^(/dev/)?(${name}|xvd${name#sd})$"; then echo "$d"; return; fi
  done
  echo "ERROR: no block device for $name" >&2; exit 1
}
DISK=$(dev_for sdf)
part() { case "$DISK" in *nvme*) echo "${DISK}p$1" ;; *) echo "${DISK}$1" ;; esac; }

# Safety: never touch the disk we are running from
ROOTSRC=$(findmnt -no SOURCE /)
case "$ROOTSRC" in "$DISK"*) echo "ERROR: target $DISK is the running root" >&2; exit 1 ;; esac

for b in sgdisk mkfs.vfat lvcreate tar grub-install; do command -v $b >/dev/null || { echo "missing $b"; exit 1; }; done

VG=cis
LVS=$(cat <<'EOF'
var     8G  /var            defaults,nodev,nosuid
varlog  4G  /var/log        defaults,nodev,nosuid,noexec
audit   2G  /var/log/audit  defaults,nodev,nosuid,noexec
vartmp  2G  /var/tmp        defaults,nodev,nosuid,noexec
home    3G  /home           defaults,nodev,nosuid
EOF
)

# ---------- 1. Partition ----------
wipefs -a "$DISK" || true
sgdisk --zap-all "$DISK"
sgdisk -n 14:2048:+4M   -t 14:ef02 -c 14:bios \
       -n 15:0:+106M    -t 15:ef00 -c 15:efi  \
       -n 1:0:+10G      -t 1:8300  -c 1:root  \
       -n 2:0:0         -t 2:8e00  -c 2:lvm   "$DISK"
partprobe "$DISK" || true
udevadm settle

mkfs.vfat -F 32 -n UEFI "$(part 15)"
mkfs.ext4 -q -F -L cis-rootfs "$(part 1)"

# LVM: never pin PVs to device serials (each launched EBS volume gets a new serial)
rm -f /etc/lvm/devices/system.devices
grep -q 'use_devicesfile' /etc/lvm/lvmlocal.conf 2>/dev/null || \
  printf '\ndevices {\n\tuse_devicesfile = 0\n}\n' >> /etc/lvm/lvmlocal.conf
pvcreate -ff -y "$(part 2)"
vgcreate "$VG" "$(part 2)"
while read -r lv size mp opts; do
  lvcreate -y -L "$size" -n "$lv" "$VG"
  mkfs.ext4 -q -F "/dev/$VG/$lv"
done <<<"$LVS"

# ---------- 2. Mount target tree ----------
T=/mnt/target
mkdir -p $T
mount "$(part 1)" $T
mkdir -p $T/var $T/home $T/boot/efi
mount /dev/$VG/var $T/var
mkdir -p $T/var/log $T/var/tmp
mount /dev/$VG/varlog $T/var/log
mkdir -p $T/var/log/audit
mount /dev/$VG/audit  $T/var/log/audit
mount /dev/$VG/vartmp $T/var/tmp
mount /dev/$VG/home   $T/home
mount "$(part 15)"    $T/boot/efi

# ---------- 3. Copy the hardened system ----------
# -x: stay on the builder root fs (skips /proc /sys /dev /run /boot/efi and /mnt/target)
# (tar, not rsync: CIS 2.1.13 removes the rsync package)
tarx() { tar --numeric-owner --xattrs "--xattrs-include=*" --acls "$@"; }
( cd / && tarx --one-file-system --exclude=./mnt/target --exclude=./lost+found --warning=no-file-changed --warning=no-file-ignored -cpf - . || [ $? -eq 1 ] ) | ( cd $T && tarx -xpf - )
# Newer Canonical images may have a separate /boot partition -> fold it into /
if mountpoint -q /boot; then ( cd /boot && tarx --one-file-system --exclude=./efi -cpf - . ) | ( cd $T/boot && tarx -xpf - ); fi
cp -r /boot/efi/. $T/boot/efi/
ls $T/boot/vmlinuz* >/dev/null
chmod 1777 $T/tmp $T/var/tmp
chmod 0750 $T/var/log/audit
mkdir -p $T/proc $T/sys $T/dev $T/run $T/mnt

# ---------- 4. fstab for the new disk ----------
ROOT_UUID=$(blkid -s UUID -o value "$(part 1)")
EFI_UUID=$(blkid -s UUID -o value "$(part 15)")
{
  echo "# CIS Ubuntu 24.04 single-disk layout"
  echo "UUID=$ROOT_UUID  /          ext4  discard,errors=remount-ro  0 1"
  echo "UUID=$EFI_UUID   /boot/efi  vfat  umask=0077                 0 1"
  while read -r lv size mp opts; do
    echo "/dev/mapper/${VG}-${lv}  $mp  ext4  $opts  0 2"
  done <<<"$LVS"
  grep -E '^\S+\s+/(tmp|dev/shm)\s' /etc/fstab || true
} > $T/etc/fstab
cat $T/etc/fstab

# ---------- 5. Bootloader (UEFI + legacy BIOS) ----------
for d in dev dev/pts proc sys run; do mount --bind /$d $T/$d; done
NEW_PARTUUID=$(blkid -s PARTUUID -o value "$(part 1)")
chroot $T /bin/bash -euxs <<CHROOT
rm -f /etc/lvm/devices/system.devices
# Ubuntu cloud images boot without initrd using GRUB_FORCE_PARTUUID: point it at the new root
if [ -f /etc/default/grub.d/40-force-partuuid.cfg ]; then
  sed -i "s/^GRUB_FORCE_PARTUUID=.*/GRUB_FORCE_PARTUUID=$NEW_PARTUUID/" /etc/default/grub.d/40-force-partuuid.cfg
fi
update-initramfs -u -k all
grub-install --target=i386-pc "$DISK"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --uefi-secure-boot --no-nvram
grub-install --target=x86_64-efi --efi-directory=/boot/efi --uefi-secure-boot --no-nvram --removable
update-grub
CHROOT

# EFI stub configs -> new root filesystem (covers both EFI/ubuntu and fallback EFI/BOOT)
for d in $T/boot/efi/EFI/ubuntu $T/boot/efi/EFI/BOOT; do
  [ -d "$d" ] || continue
  cat > "$d/grub.cfg" <<EOF
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
EOF
done
grep -q "$ROOT_UUID" $T/boot/grub/grub.cfg
grep -E "GRUB_FORCE_PARTUUID" $T/etc/default/grub.d/40-force-partuuid.cfg 2>/dev/null || true

# ---------- 6. Unmount ----------
for d in run sys proc dev/pts dev; do umount $T/$d; done
sync
umount $T/boot/efi $T/home $T/var/tmp $T/var/log/audit $T/var/log $T/var $T
vgchange -an "$VG"
rmdir $T
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$DISK"
echo "single-disk image ready on $DISK"
