# Copy this to config.sh and edit it.
#   cp config.example.sh config.sh
# Then run:
#   bash install.sh

# 128GB OS/boot SSD (WILL BE ERASED)
OS_DISK="/dev/nvme0n1"

# 4× 4TB NVMe data disks (WILL BE ERASED)
# Example only — you MUST set your real disk names:
DATA_DISKS=(/dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1)

# Host identity
HOSTNAME="kintoun"
USERNAME="admin"

# Locale/time
TIMEZONE="America/Chicago"
LOCALE="en_US.UTF-8"

# OS partitioning
EFI_SIZE="1G"

# Btrfs pool settings
MEDIA_LABEL="media"
MEDIA_MOUNT="/media"

# Mount options (RAID0-focused, no autodefrag)
# - noatime: reduces metadata writes on reads
# - compress=zstd:1: good general default on NVMe (tweak if you want)
# - space_cache=v2: modern free-space cache
MEDIA_MOUNT_OPTIONS="noatime,compress=zstd:1,space_cache=v2"

# Script is RAID0-only by request
DATA_PROFILE="raid0"
