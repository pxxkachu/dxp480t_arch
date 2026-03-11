#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Arch installer for UGREEN DXP480T Plus
# - OS: ext4 on OS_DISK (/dev/nvme3n1)
# - Data: Btrfs RAID0 pool on DATA_DISKS
# -----------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config.sh}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Missing config file: $CONFIG_PATH"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_PATH"

# ---- Required config variables ----
: "${OS_DISK:?Set OS_DISK in config.sh (e.g. /dev/nvme3n1)}"
: "${HOSTNAME:?}"
: "${USERNAME:?}"
: "${TIMEZONE:?}"
: "${LOCALE:?}"
: "${EFI_SIZE:?}"
: "${MEDIA_LABEL:?}"
: "${MEDIA_MOUNT:?}"
: "${MEDIA_MOUNT_OPTIONS:?}"

# Array length check (fixed syntax)
if [[ ${#DATA_DISKS[@]} -lt 2 ]]; then
  echo "ERROR: DATA_DISKS must contain at least 2 disks."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

# NVMe partition naming helper
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
    pacman -Sy --noconfirm --needed "$pkg"
  fi
}

echo "== Ensuring required tools exist =="
need_cmd_or_install pacstrap arch-install-scripts
need_cmd_or_install sgdisk gptfdisk

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  DANGER: THIS WILL ERASE $OS_DISK AND ${DATA_DISKS[*]}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -r -p "Type ERASE to continue: " CONFIRM
[[ "$CONFIRM" == "ERASE" ]] || exit 1

timedatectl set-ntp true || true

EFI_PART="$(part "$OS_DISK" 1)"
ROOT_PART="$(part "$OS_DISK" 2)"

echo "== Partitioning OS disk ($OS_DISK) =="
sgdisk --zap-all "$OS_DISK"
sgdisk -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI"  "$OS_DISK"
sgdisk -n 2:0:0           -t 2:8300 -c 2:"ROOT" "$OS_DISK"
sleep 2

echo "== Formatting OS partitions =="
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F -L archroot "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "== Partitioning data disks =="
DATA_PARTS=()
for d in "${DATA_DISKS[@]}"; do
  p1="$(part "$d" 1)"
  sgdisk --zap-all "$d"
  sgdisk -n 1:0:0 -t 1:8300 -c 1:"BTRFS_DATA" "$d"
  sleep 1
  wipefs -a "$p1" || true
  DATA_PARTS+=("$p1")
done

echo "== Creating Btrfs pool =="
mkfs.btrfs -f -L "$MEDIA_LABEL" -d raid0 -m raid1 "${DATA_PARTS[@]}"
mkdir -p "/mnt${MEDIA_MOUNT}"
mount -t btrfs "LABEL=${MEDIA_LABEL}" "/mnt${MEDIA_MOUNT}"

echo "== Installing Packages (Base + NAS Tools) =="
pacstrap -K /mnt \
  base linux linux-firmware btrfs-progs intel-ucode \
  sudo git nano networkmanager base-devel \
  openssh bolt ethtool smartmontools nvme-cli

genfstab -U /mnt >> /mnt/etc/fstab

echo "== Configuring system inside chroot =="
arch-chroot /mnt /bin/bash -euo pipefail <<EOF
# Time and Locale
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# User setup
if ! id "${USERNAME}" &>/dev/null; then
  useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel

# systemd-boot
bootctl install
ROOTUUID=\$(blkid -s UUID -o value "${ROOT_PART}")

cat > /boot/loader/entries/arch.conf <<E
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=\${ROOTUUID} rw nvme_core.default_ps_max_latency_us=0
E
echo "default arch.conf" > /boot/loader/loader.conf

# Services (with || true to prevent script exit on missing optional units)
systemctl enable NetworkManager || true
systemctl enable sshd || true
systemctl enable boltd || true
systemctl enable smartd || true
systemctl enable fstrim.timer || true
EOF

echo "== Set passwords =="
echo "Root:"
arch-chroot /mnt passwd
echo "User ${USERNAME}:"
arch-chroot /mnt passwd "${USERNAME}"

umount -R /mnt
echo "Installation complete. Rebooting..."
reboot
