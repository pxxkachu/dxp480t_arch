# UGREEN Arch Installer (Btrfs RAID0 /media)

This installs Arch Linux to a dedicated OS SSD and creates a Btrfs multi-device filesystem across 4 NVMe drives:
- data profile: RAID0
- metadata profile: RAID1 (recommended)

The Btrfs filesystem is mounted at: `/media`

## WARNING
This script **ERASES** the OS disk and ALL NVMe data disks you specify. Double-check disk names.

## Before you start
1. In BIOS: **Disable the hardware watchdog** (important on UGREEN boxes when not running UGOS).
2. Disable Secure Boot (if enabled).
3. Boot the latest Arch ISO in UEFI mode.

## Steps (live Arch ISO)
1. Verify network:
   ```bash
   ping -c 3 archlinux.org
