#!/usr/bin/env bash
#
# Run from the official Arch Linux live ISO, UEFI boot, as root.
# This script DESTROYS all data on the disks you select (OS + data array).
# BIOS: disable the hardware watchdog on UGREEN boxes when not running UGOS;
# disable Secure Boot if enabled; use UEFI (not CSM/Legacy).
# Ensure networking works (e.g. ping archlinux.org) before continuing.
#
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# -----------------------------
# Arch installer for UGREEN DXP480T Plus
# - OS: ext4 on a user-selected NVMe/SATA disk
# - Data: Btrfs RAID0 pool on user-selected disks
# - Fully interactive — no config file
# -----------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "ERROR: Not booted in UEFI mode. This script requires UEFI."
  echo "Reboot and ensure UEFI boot is selected in BIOS, not CSM/Legacy."
  exit 1
fi

export LC_ALL=C

# ---- Cleanup trap ----
cleanup() {
  echo "== Cleanup: unmounting filesystems =="
  umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

err_exit() {
  echo "ERROR: $*" >&2
  exit 1
}

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

# True if any descendant block device currently has a non-empty MOUNTPOINT.
disk_has_mounts() {
  local disk="$1"
  lsblk -n -o MOUNTPOINT "$disk" | awk 'NF { exit 0 } END { exit 1 }'
}

assert_whole_disk() {
  local d="$1" t
  [[ -b "$d" ]] || err_exit "Not a block device: $d"
  t="$(lsblk -dn -o TYPE "$d" 2>/dev/null || true)"
  [[ "$t" == "disk" ]] || err_exit "Expected a whole disk (not a partition): $d (lsblk TYPE=${t:-unknown})"
}

assert_disk_not_readonly() {
  local d="$1"
  if [[ "$(blockdev --getro "$d" 2>/dev/null || echo 0)" == "1" ]]; then
    err_exit "Disk is read-only: $d"
  fi
}

assert_partitions_exist() {
  local p
  for p in "$@"; do
    [[ -b "$p" ]] || err_exit "Partition not found (kernel may need a moment): $p"
  done
}

reread_partition_table() {
  local d
  for d in "$@"; do
    blockdev --rereadpt "$d" 2>/dev/null || true
  done
}

echo "== Ensuring required tools exist =="
need_cmd pacstrap    arch-install-scripts
need_cmd sgdisk      gptfdisk
need_cmd wipefs      util-linux
need_cmd mkfs.fat    dosfstools
need_cmd mkfs.ext4   e2fsprogs
need_cmd mkfs.btrfs  btrfs-progs
need_cmd lsblk       util-linux
need_cmd blockdev    util-linux

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
    err_exit "No disks found."
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
  if [[ "$EFI_SIZE" =~ ^[1-9][0-9]*(M|G)$ ]]; then
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
  err_exit "Need at least 2 remaining disks for the data array, but only ${#REMAINING_DISKS[@]} available."
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
    if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > ${#REMAINING_DISKS[@]} )); then
      echo "Invalid number: $c. Enter numbers between 1 and ${#REMAINING_DISKS[@]}."
      valid=false
      break
    fi
    disk="${REMAINING_DISKS[$((c - 1))]}"
    for already in "${DATA_DISKS[@]}"; do
      if [[ "$already" == "$disk" ]]; then
        echo "Duplicate selection: $disk. Each disk can only be selected once."
        valid=false
        break 2
      fi
    done
    DATA_DISKS+=("$disk")
  done
  $valid && break
done

echo "  -> Data disks: ${DATA_DISKS[*]}"
echo ""

# -- System identity --
while true; do
  read -r -p "Hostname (e.g. kintoun): " HOSTNAME
  if [[ "$HOSTNAME" =~ ^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    break
  fi
  echo "Invalid hostname. Letters, digits, and hyphens only. Must start with a letter, must not end with a hyphen (max 63 chars)."
done

while true; do
  read -r -p "Username (e.g. admin): " USERNAME
  if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    break
  fi
  echo "Invalid username. Use lowercase letters, digits, underscores, and hyphens. Must start with a letter or underscore (max 32 chars)."
done

echo ""
echo "Timezone examples: America/Chicago, America/New_York, Europe/London, Asia/Tokyo"
while true; do
  read -r -p "Timezone (e.g. America/Chicago): " TIMEZONE
  if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    break
  fi
  echo "Invalid timezone. File /usr/share/zoneinfo/${TIMEZONE} not found. Use a valid tz database name."
done

echo ""
echo "Locale examples: en_US.UTF-8, en_GB.UTF-8, de_DE.UTF-8, ja_JP.UTF-8"
while true; do
  read -r -p "Locale (e.g. en_US.UTF-8): " LOCALE
  if grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null; then
    break
  fi
  echo "Invalid locale. '${LOCALE}' not found in /etc/locale.gen. Use a locale listed there (e.g. en_US.UTF-8)."
done

echo ""
while true; do
  read -r -p "Data array label (e.g. media): " MEDIA_LABEL
  if [[ "$MEDIA_LABEL" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$ ]]; then
    break
  fi
  echo "Invalid label. Use letters, digits, dots, hyphens, underscores. Must start with a letter or digit (max 255 chars)."
done

while true; do
  read -r -p "Data array mount point (e.g. /media): " MEDIA_MOUNT
  if [[ "$MEDIA_MOUNT" =~ ^/[a-zA-Z0-9._/-]+$ ]]; then
    break
  fi
  echo "Invalid mount point. Must be an absolute path (start with /) with no spaces or special characters."
done

# ---- Pre-destructive checks ----
TARGET_DISKS=("$OS_DISK" "${DATA_DISKS[@]}")
for d in "${TARGET_DISKS[@]}"; do
  assert_whole_disk "$d"
  assert_disk_not_readonly "$d"
  if disk_has_mounts "$d"; then
    err_exit "Refusing to erase $d: one or more partitions are mounted. Unmount them first."
  fi
done

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

if mountpoint -q /mnt; then
  echo "== /mnt is already mounted — cleaning up previous run =="
  umount -R /mnt
fi

EFI_PART="$(part "$OS_DISK" 1)"
ROOT_PART="$(part "$OS_DISK" 2)"

# ---- OS disk ----
echo "== Partitioning OS disk ($OS_DISK) =="
sgdisk --zap-all "$OS_DISK"
sgdisk -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI"  "$OS_DISK"
sgdisk -n 2:0:0            -t 2:8300 -c 2:"ROOT" "$OS_DISK"
wait_for_partitions
reread_partition_table "$OS_DISK"
wait_for_partitions
assert_partitions_exist "$EFI_PART" "$ROOT_PART"

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
reread_partition_table "${DATA_DISKS[@]}"
wait_for_partitions
assert_partitions_exist "${DATA_PARTS[@]}"

for p in "${DATA_PARTS[@]}"; do
  wipefs -af "$p"
done

echo "== Creating Btrfs pool =="
mkfs.btrfs -f -L "$MEDIA_LABEL" -d raid0 -m raid1 "${DATA_PARTS[@]}"

echo "== Creating Btrfs subvolumes =="
mkdir -p /mnt/btrfs-setup
mount -t btrfs "LABEL=${MEDIA_LABEL}" /mnt/btrfs-setup
btrfs subvolume create /mnt/btrfs-setup/@media
btrfs subvolume create /mnt/btrfs-setup/@snapshots
umount /mnt/btrfs-setup
rmdir /mnt/btrfs-setup

mkdir -p "/mnt${MEDIA_MOUNT}" "/mnt${MEDIA_MOUNT}/.snapshots"
mount -t btrfs -o "${MEDIA_MOUNT_OPTIONS},subvol=@media" "LABEL=${MEDIA_LABEL}" "/mnt${MEDIA_MOUNT}"
mount -t btrfs -o "${MEDIA_MOUNT_OPTIONS},subvol=@snapshots" "LABEL=${MEDIA_LABEL}" "/mnt${MEDIA_MOUNT}/.snapshots"

# ---- Base system ----
echo "== Checking network connectivity =="
if ! curl -fsS --connect-timeout 10 --max-time 30 https://archlinux.org >/dev/null; then
  err_exit "No network. Verify connectivity before running this script."
fi

echo "== Selecting fastest mirrors =="
need_cmd reflector reflector
reflector --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist

echo "== Pre-creating config files needed during package install =="
mkdir -p /mnt/etc
echo "KEYMAP=us" > /mnt/etc/vconsole.conf

echo "== Installing packages =="
pacstrap -K /mnt \
  base linux linux-headers linux-firmware btrfs-progs intel-ucode zstd \
  sudo git nano networkmanager base-devel \
  openssh bolt ethtool smartmontools nvme-cli \
  zram-generator

genfstab -U /mnt > /mnt/etc/fstab

# ---- Chroot configuration ----
echo "== Configuring system inside chroot =="
if ! arch-chroot /mnt /bin/bash -euo pipefail <<EOF
# Time and Locale
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i 's/^#\(${LOCALE//./\\.} UTF-8\)/\1/' /etc/locale.gen
grep -q "^${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

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
timeout 0
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

# Btrfs daily snapshot script for media array
cat > /usr/local/bin/btrfs-snapshot-media <<'SNAPSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SNAP_DIR="SNAP_MOUNT_PLACEHOLDER/.snapshots"
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
KEEP=7
btrfs subvolume snapshot -r "SNAP_MOUNT_PLACEHOLDER" "\${SNAP_DIR}/\${TIMESTAMP}"
echo "Created snapshot: \${SNAP_DIR}/\${TIMESTAMP}"
mapfile -t ALL < <(ls -1d "\${SNAP_DIR}"/2* 2>/dev/null | sort)
if (( \${#ALL[@]} > KEEP )); then
  DELETE=("\${ALL[@]:0:\${#ALL[@]}-KEEP}")
  for snap in "\${DELETE[@]}"; do
    btrfs subvolume delete "\$snap"
    echo "Deleted old snapshot: \$snap"
  done
fi
SNAPSCRIPT
sed -i "s|SNAP_MOUNT_PLACEHOLDER|${MEDIA_MOUNT}|g" /usr/local/bin/btrfs-snapshot-media
chmod +x /usr/local/bin/btrfs-snapshot-media

cat > /etc/systemd/system/btrfs-snapshot-media.service <<'SNAPSVC'
[Unit]
Description=Btrfs snapshot of media array

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot-media
SNAPSVC

cat > /etc/systemd/system/btrfs-snapshot-media.timer <<'SNAPTIMER'
[Unit]
Description=Daily Btrfs snapshot of media array

[Timer]
OnCalendar=daily
AccuracySec=1h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
SNAPTIMER

systemctl enable btrfs-snapshot-media.timer

# zram swap (compressed RAM-backed swap, no disk I/O)
mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf.d/zram.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# Hardware watchdog (Intel iTCO_wdt)
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/watchdog.conf <<WDT
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=10min
WDT

# Rebuild initramfs with all config in place
mkinitcpio -P

# Services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable bolt
systemctl enable smartd
systemctl enable systemd-timesyncd
systemctl enable fstrim.timer
EOF
then
  err_exit "arch-chroot configuration failed. See messages above. /mnt may still be mounted for inspection."
fi

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
