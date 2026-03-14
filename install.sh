#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Arch installer for UGREEN DXP480T Plus
# - OS: ext4 on a user-selected NVMe/SATA disk
# - Data: Btrfs RAID0 pool on user-selected disks
# - Fully interactive — no config file needed
# -----------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

# ---- Cleanup trap ----
cleanup() {
  echo "== Cleanup: unmounting filesystems =="
  umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

# ---- Helpers ----

part() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ (nvme|mmcblk) ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

wait_for_partitions() {
  udevadm settle --timeout=10
}

need_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 || pacman -Sy --noconfirm --needed "$pkg"
}

echo "== Ensuring required tools exist =="
need_cmd pacstrap arch-install-scripts
need_cmd sgdisk   gptfdisk
need_cmd wipefs   util-linux

# Btrfs mount options (not prompted)
MEDIA_MOUNT_OPTIONS="noatime,compress=zstd:1,space_cache=v2"

# ---- Disk discovery ----
discover_disks() {
  AVAILABLE_DISKS=()
  AVAILABLE_SIZES=()
  AVAILABLE_MODELS=()
  while IFS= read -r line; do
    local name size model
    name="$(echo "$line" | awk '{print $1}')"
    size="$(echo "$line" | awk '{print $2}')"
    model="$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')"
    [[ -z "$model" ]] && model="(unknown)"
    AVAILABLE_DISKS+=("$name")
    AVAILABLE_SIZES+=("$size")
    AVAILABLE_MODELS+=("$model")
  done < <(lsblk -dpno NAME,SIZE,MODEL | grep -E '/dev/(sd|nvme|mmcblk)')

  if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
    echo "ERROR: No disks found."
    exit 1
  fi
}

print_disk_table() {
  local disks=("$@")
  printf "  %-4s  %-15s  %-10s  %s\n" "#" "DISK" "SIZE" "MODEL"
  printf "  %-4s  %-15s  %-10s  %s\n" "---" "---------------" "----------" "-----"
  local idx=1
  for d in "${disks[@]}"; do
    local i
    for i in "${!AVAILABLE_DISKS[@]}"; do
      if [[ "${AVAILABLE_DISKS[$i]}" == "$d" ]]; then
        printf "  %-4s  %-15s  %-10s  %s\n" "$idx" "$d" "${AVAILABLE_SIZES[$i]}" "${AVAILABLE_MODELS[$i]}"
        break
      fi
    done
    ((idx++))
  done
}

# ---- Interactive configuration ----
echo ""
echo "========================================"
echo "  Arch Linux NAS Installer"
echo "========================================"
echo ""

discover_disks

# -- OS disk selection --
echo "== Available disks =="
print_disk_table "${AVAILABLE_DISKS[@]}"
echo ""
while true; do
  read -r -p "Select the OS disk by number (e.g. 1): " OS_CHOICE
  if [[ "$OS_CHOICE" =~ ^[0-9]+$ ]] && (( OS_CHOICE >= 1 && OS_CHOICE <= ${#AVAILABLE_DISKS[@]} )); then
    OS_DISK="${AVAILABLE_DISKS[$((OS_CHOICE - 1))]}"
    break
  fi
  echo "Invalid selection. Enter a number between 1 and ${#AVAILABLE_DISKS[@]}."
done
echo "  -> OS disk: $OS_DISK"
echo ""

# -- EFI partition size --
while true; do
  read -r -p "EFI partition size (e.g. 512M, 1G): " EFI_SIZE
  if [[ "$EFI_SIZE" =~ ^[0-9]+(M|G)$ ]]; then
    break
  fi
  echo "Invalid format. Use a number followed by M or G (e.g. 512M, 1G)."
done
echo ""

# -- Data disk selection --
REMAINING_DISKS=()
for d in "${AVAILABLE_DISKS[@]}"; do
  [[ "$d" != "$OS_DISK" ]] && REMAINING_DISKS+=("$d")
done

if [[ ${#REMAINING_DISKS[@]} -lt 2 ]]; then
  echo "ERROR: Need at least 2 remaining disks for the data array, but only ${#REMAINING_DISKS[@]} available."
  exit 1
fi

echo "== Available disks for data array (OS disk excluded) =="
print_disk_table "${REMAINING_DISKS[@]}"
echo ""

while true; do
  read -r -p "How many disks for the data array? (min 2, max ${#REMAINING_DISKS[@]}): " DATA_COUNT
  if [[ "$DATA_COUNT" =~ ^[0-9]+$ ]] && (( DATA_COUNT >= 2 && DATA_COUNT <= ${#REMAINING_DISKS[@]} )); then
    break
  fi
  echo "Invalid. Enter a number between 2 and ${#REMAINING_DISKS[@]}."
done

DATA_DISKS=()
while true; do
  read -r -p "Select $DATA_COUNT disks by number, space-separated (e.g. 1 2 3 4): " -a DATA_CHOICES
  if [[ ${#DATA_CHOICES[@]} -ne $DATA_COUNT ]]; then
    echo "Please select exactly $DATA_COUNT disks."
    continue
  fi
  valid=true
  DATA_DISKS=()
  for c in "${DATA_CHOICES[@]}"; do
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#REMAINING_DISKS[@]} )); then
      DATA_DISKS+=("${REMAINING_DISKS[$((c - 1))]}")
    else
      echo "Invalid number: $c. Enter numbers between 1 and ${#REMAINING_DISKS[@]}."
      valid=false
      break
    fi
  done
  $valid && break
done

echo "  -> Data disks: ${DATA_DISKS[*]}"
echo ""

# -- System identity --
read -r -p "Hostname (e.g. kintoun): " HOSTNAME
read -r -p "Username (e.g. admin): " USERNAME

echo ""
echo "Timezone examples: America/Chicago, America/New_York, Europe/London, Asia/Tokyo"
read -r -p "Timezone (e.g. America/Chicago): " TIMEZONE

echo ""
echo "Locale examples: en_US.UTF-8, en_GB.UTF-8, de_DE.UTF-8, ja_JP.UTF-8"
read -r -p "Locale (e.g. en_US.UTF-8): " LOCALE

echo ""
read -r -p "Data array label (e.g. media): " MEDIA_LABEL
read -r -p "Data array mount point (e.g. /media): " MEDIA_MOUNT

# ---- Summary and confirmation ----
echo ""
echo "========================================"
echo "  Configuration Summary"
echo "========================================"
echo ""
echo "  OS disk:          $OS_DISK"
echo "  EFI size:         $EFI_SIZE"
echo "  Data disks:       ${DATA_DISKS[*]}"
echo "  Data RAID:        RAID0 (data) / RAID1 (metadata)"
echo "  Mount options:    $MEDIA_MOUNT_OPTIONS"
echo ""
echo "  Hostname:         $HOSTNAME"
echo "  Username:         $USERNAME"
echo "  Timezone:         $TIMEZONE"
echo "  Locale:           $LOCALE"
echo ""
echo "  Array label:      $MEDIA_LABEL"
echo "  Array mount:      $MEDIA_MOUNT"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  DANGER: THIS WILL ERASE: $OS_DISK ${DATA_DISKS[*]}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -r -p "Type ERASE to continue: " CONFIRM
[[ "$CONFIRM" == "ERASE" ]] || exit 1

timedatectl set-ntp true || true

EFI_PART="$(part "$OS_DISK" 1)"
ROOT_PART="$(part "$OS_DISK" 2)"

# ---- OS disk ----
echo "== Partitioning OS disk ($OS_DISK) =="
sgdisk --zap-all "$OS_DISK"
sgdisk -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI"  "$OS_DISK"
sgdisk -n 2:0:0            -t 2:8300 -c 2:"ROOT" "$OS_DISK"
wait_for_partitions

echo "== Formatting OS partitions =="
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F -L archroot "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount -o fmask=0077,dmask=0077 "$EFI_PART" /mnt/boot

# ---- Data disks ----
echo "== Partitioning data disks =="
DATA_PARTS=()
for d in "${DATA_DISKS[@]}"; do
  sgdisk --zap-all "$d"
  sgdisk -n 1:0:0 -t 1:8300 -c 1:"BTRFS_DATA" "$d"
  DATA_PARTS+=("$(part "$d" 1)")
done
wait_for_partitions

for p in "${DATA_PARTS[@]}"; do
  wipefs -af "$p"
done

echo "== Creating Btrfs pool =="
mkfs.btrfs -f -L "$MEDIA_LABEL" -d raid0 -m raid1 "${DATA_PARTS[@]}"
mkdir -p "/mnt${MEDIA_MOUNT}"
mount -t btrfs -o "${MEDIA_MOUNT_OPTIONS}" "LABEL=${MEDIA_LABEL}" "/mnt${MEDIA_MOUNT}"

# ---- Base system ----
echo "== Installing packages =="
pacstrap -K /mnt \
  base linux linux-headers linux-firmware btrfs-progs intel-ucode zstd \
  sudo git nano networkmanager base-devel \
  openssh bolt ethtool smartmontools nvme-cli

genfstab -U /mnt >> /mnt/etc/fstab

# ---- Chroot configuration ----
echo "== Configuring system inside chroot =="
arch-chroot /mnt /bin/bash -euo pipefail <<EOF
# Time and Locale
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i 's/^#\(${LOCALE} UTF-8\)/\1/' /etc/locale.gen
grep -q "^${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname and hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

# User setup
if ! id "${USERNAME}" &>/dev/null; then
  useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel

# systemd-boot
bootctl install
ROOTUUID=\$(blkid -s UUID -o value "${ROOT_PART}")

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=\${ROOTUUID} rw nvme_core.default_ps_max_latency_us=0
ENTRY

cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
editor  no
LOADER

# Btrfs monthly scrub timer
cat > /etc/systemd/system/btrfs-scrub@.timer <<TIMER
[Unit]
Description=Monthly Btrfs scrub on %f

[Timer]
OnCalendar=monthly
AccuracySec=1d
RandomizedDelaySec=1w
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/btrfs-scrub@.service <<SVC
[Unit]
Description=Btrfs scrub on %f

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/btrfs scrub start -B %f
SVC

systemctl enable btrfs-scrub@$(systemd-escape -p "${MEDIA_MOUNT}").timer

# Hardware watchdog (Intel iTCO_wdt)
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/watchdog.conf <<WDT
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=10min
WDT

# Services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable bolt
systemctl enable smartd
systemctl enable fstrim.timer
EOF

# ---- Passwords (interactive with retry) ----
set_passwd() {
  local user="$1" label="$2"
  while true; do
    echo "${label}:"
    if arch-chroot /mnt passwd "$user"; then
      break
    fi
    echo "Password not set. Try again."
  done
}

echo "== Set passwords =="
set_passwd root "Root"
set_passwd "${USERNAME}" "User ${USERNAME}"

trap - EXIT
umount -R /mnt
echo "Installation complete. Rebooting..."
reboot
