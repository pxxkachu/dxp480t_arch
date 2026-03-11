#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Arch installer for UGREEN-like NAS
# - OS: ext4 on OS_DISK
# - Data: Btrfs across DATA_DISKS with -d raid0 -m raid1
# - Mountpoint: /media
# -----------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config.sh}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Missing config file: $CONFIG_PATH"
  echo "Create it with: cp config.example.sh config.sh && edit config.sh"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_PATH"

# ---- Required config variables ----
: "${OS_DISK:?Set OS_DISK in config.sh (e.g. /dev/nvme0n1)}"
: "${HOSTNAME:?Set HOSTNAME in config.sh}"
: "${USERNAME:?Set USERNAME in config.sh}"
: "${TIMEZONE:?Set TIMEZONE in config.sh}"
: "${LOCALE:?Set LOCALE in config.sh}"
: "${EFI_SIZE:?Set EFI_SIZE in config.sh (e.g. 1G)}"
: "${MEDIA_LABEL:?Set MEDIA_LABEL in config.sh (e.g. media)}"
: "${MEDIA_MOUNT:?Set MEDIA_MOUNT in config.sh (e.g. /media)}"
: "${MEDIA_MOUNT_OPTIONS:?Set MEDIA_MOUNT_OPTIONS in config.sh}"

# DATA_DISKS must be an array
if [[ "${#DATA_DISKS[@]:-0}" -lt 2 ]]; then
  echo "ERROR: DATA_DISKS must contain at least 2 disks (you have: ${#DATA_DISKS[@]:-0})."
  exit 1
fi

if [[ "${DATA_PROFILE:-raid0}" != "raid0" ]]; then
  echo "ERROR: This installer is RAID0-focused. Set DATA_PROFILE=\"raid0\" in config.sh."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (live Arch ISO usually boots to root)."
  exit 1
fi

part() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ (nvme|mmcblk) ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

need_cmd_or_install() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing '$cmd' - installing package '$pkg' in live environment..."
    pacman -Sy --noconfirm --needed "$pkg"
  fi
}

ensure_live_tools() {
  need_cmd_or_install pacstrap arch-install-scripts
  need_cmd_or_install genfstab arch-install-scripts
  need_cmd_or_install arch-chroot arch-install-scripts
  need_cmd_or_install sgdisk gptfdisk
  need_cmd_or_install mkfs.fat dosfstools
  need_cmd_or_install mkfs.ext4 e2fsprogs
  need_cmd_or_install mkfs.btrfs btrfs-progs
  need_cmd_or_install wipefs util-linux
}

disk_exists() {
  [[ -b "$1" ]]
}

echo "== Ensuring required tools exist in the live ISO =="
ensure_live_tools

echo
echo "== Disk overview (VERIFY THIS CAREFULLY) =="
lsblk -o NAME,SIZE,MODEL,TYPE
echo

echo "== Configuration summary =="
echo "OS_DISK        : $OS_DISK"
echo "OS EFI size    : $EFI_SIZE"
echo "DATA_DISKS     : ${DATA_DISKS[*]}"
echo "Btrfs label    : $MEDIA_LABEL"
echo "Mountpoint     : $MEDIA_MOUNT"
echo "Btrfs profile  : data=raid0, metadata=raid1"
echo "Mount options  : $MEDIA_MOUNT_OPTIONS"
echo

# Validate block devices exist
if ! disk_exists "$OS_DISK"; then
  echo "ERROR: OS_DISK does not exist: $OS_DISK"
  exit 1
fi

for d in "${DATA_DISKS[@]}"; do
  if ! disk_exists "$d"; then
    echo "ERROR: DATA_DISK does not exist: $d"
    exit 1
  fi
done

# Ensure OS_DISK not listed among DATA_DISKS
for d in "${DATA_DISKS[@]}"; do
  if [[ "$d" == "$OS_DISK" ]]; then
    echo "ERROR: OS_DISK is also listed in DATA_DISKS. Fix config.sh."
    exit 1
  fi
done

echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  DANGER: THIS WILL ERASE THE OS DISK AND ALL DATA DISKS"
echo "  OS_DISK    = $OS_DISK"
echo "  DATA_DISKS = ${DATA_DISKS[*]}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo
read -r -p "Type ERASE to continue: " CONFIRM
if [[ "$CONFIRM" != "ERASE" ]]; then
  echo "Aborted."
  exit 1
fi

echo "== Best-effort time sync =="
timedatectl set-ntp true >/dev/null 2>&1 || true

EFI_PART="$(part "$OS_DISK" 1)"
ROOT_PART="$(part "$OS_DISK" 2)"

echo "== Partitioning OS disk ($OS_DISK) =="
sgdisk --zap-all "$OS_DISK"
sgdisk -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI"  "$OS_DISK"
sgdisk -n 2:0:0          -t 2:8300 -c 2:"ROOT" "$OS_DISK"

echo "== Formatting OS partitions =="
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F -L archroot "$ROOT_PART"

echo "== Mounting OS target =="
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "== Partitioning data disks (single partition each) =="
DATA_PARTS=()
for d in "${DATA_DISKS[@]}"; do
  p1="$(part "$d" 1)"
  echo "  -> $d"
  sgdisk --zap-all "$d"
  sgdisk -n 1:0:0 -t 1:8300 -c 1:"BTRFS_${MEDIA_LABEL}" "$d"
  wipefs -a "$p1" >/dev/null 2>&1 || true
  DATA_PARTS+=("$p1")
done

echo "== Creating Btrfs filesystem (data=raid0, metadata=raid1) =="
mkfs.btrfs -f -L "$MEDIA_LABEL" -d raid0 -m raid1 "${DATA_PARTS[@]}"

echo "== Mounting Btrfs pool into target at /mnt${MEDIA_MOUNT} =="
mkdir -p "/mnt${MEDIA_MOUNT}"
mount -t btrfs "LABEL=${MEDIA_LABEL}" "/mnt${MEDIA_MOUNT}"

echo "== Installing Arch packages =="
pacstrap -K /mnt \
  base linux linux-lts linux-firmware intel-ucode \
  sudo vim git tmux \
  networkmanager openssh \
  btrfs-progs mbuffer btrfsmaintenance \
  nvme-cli smartmontools \
  bolt \
  ethtool iperf3 \
  lm_sensors thermald irqbalance \
  chrony

echo "== Generating fstab =="
genfstab -U /mnt > /mnt/etc/fstab

echo "== Forcing /media fstab line with desired options =="
MEDIA_UUID="$(blkid -s UUID -o value "${DATA_PARTS[0]}")"

# Remove any existing fstab line that mounts to MEDIA_MOUNT, then append ours.
tmp="$(mktemp)"
awk '$2 != "'"$MEDIA_MOUNT"'" {print}' /mnt/etc/fstab > "$tmp"
mv "$tmp" /mnt/etc/fstab
echo "UUID=${MEDIA_UUID}  ${MEDIA_MOUNT}  btrfs  ${MEDIA_MOUNT_OPTIONS}  0  0" >> /mnt/etc/fstab

echo "== Configuring system inside chroot =="
arch-chroot /mnt /bin/bash -euo pipefail <<EOF
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#${LOCALE} UTF-8/${LOCALE} UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname + hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1  localhost
::1        localhost
127.0.1.1  ${HOSTNAME}.localdomain ${HOSTNAME}
H

# User + sudo (wheel)
useradd -m -G wheel -s /bin/bash "${USERNAME}" || true
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel

# Bootloader: systemd-boot
bootctl install
ROOTUUID=\$(blkid -s UUID -o value "${ROOT_PART}")

cat > /boot/loader/entries/arch.conf <<E
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=\${ROOTUUID} rw
E

# Services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable chronyd
systemctl enable thermald
systemctl enable irqbalance
systemctl enable smartd
systemctl enable boltd
systemctl enable fstrim.timer

# btrfsmaintenance: set mountpoints; enable scrub timer (safe default)
if [[ -f /etc/default/btrfsmaintenance ]]; then
  sed -i 's|^BTRFS_MAINTENANCE_MOUNTPOINTS=.*|BTRFS_MAINTENANCE_MOUNTPOINTS="'"${MEDIA_MOUNT}"'"|' /etc/default/btrfsmaintenance || true
  systemctl enable btrfs-scrub.timer || true
fi
EOF

echo
echo "== Set passwords (interactive) =="
echo "Root password:"
arch-chroot /mnt passwd
echo
echo "User password for ${USERNAME}:"
arch-chroot /mnt passwd "${USERNAME}"

echo
echo "== Installation complete. Unmounting and rebooting =="
umount -R /mnt
reboot
