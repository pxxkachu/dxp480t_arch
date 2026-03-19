# Btrfs media pool migration: staging → fresh array → `/media`

This document describes moving data off an existing **`/media`** Btrfs pool to **`/data/media-staging`**, recreating a **new** multi-device filesystem with **`@media`** + **`@snapshots`** (installer-style layout), restoring data, mounting **`/media/.snapshots`**, and creating the **first read-only snapshot**.

**Warnings**

- Steps that **partition**, **`wipefs`**, or **`mkfs.btrfs`** are **destructive** for the listed NVMe disks.
- Confirm the four disks are **only** the data array (not the OS disk).
- This guide uses **`nvme0n1`, `nvme1n1`, `nvme2n1`, `nvme4n1`** — there is **no `nvme3n1`**. If your pool should include **`nvme3n1`**, add it to every disk list below.
- Staging on **`/data`** is a **single point of failure** until the new pool is verified; keep the staging copy until you are satisfied.
- **Hard links:** use **`rsync -H`** on **both** copy legs so link structure is preserved across filesystems.

---

## Prerequisites

- Enough free space on **`/data`** for a full copy of **`/media`**.
- **`rsync`** installed.
- **`sgdisk`** / **`gptfdisk`** (script below installs via `pacman` if missing).
- Root/sudo for all destructive steps.

---

## 1. Variables (edit if needed)

```bash
STAGING=/data/media-staging
MEDIA_LABEL=media
MEDIA_MOUNT=/media
OPTS=noatime,compress=zstd:1,space_cache=v2

# Whole disks that form ONE Btrfs filesystem (must NOT include the OS disk)
DISKS=(/dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme4n1)
```

Member partitions after GPT setup (NVMe naming):

```bash
DATA_PARTS=(/dev/nvme0n1p1 /dev/nvme1n1p1 /dev/nvme2n1p1 /dev/nvme4n1p1)
```

---

## 2. Stop services using `/media`

Stop SMB/NFS, torrent, *arr apps, Plex, Docker stacks, or anything with open files under **`/media`**.

```bash
sudo systemctl stop smbd nmbd 2>/dev/null || true
sudo systemctl stop nfs-server 2>/dev/null || true
# Add anything else that uses /media.

sudo lsof +f -- /media 2>/dev/null || true
```

Resolve any processes listed before continuing.

---

## 3. Unmount nested snapshots (if present)

```bash
if mountpoint -q "${MEDIA_MOUNT}/.snapshots"; then
  sudo umount "${MEDIA_MOUNT}/.snapshots"
fi
```

---

## 4. Copy data from `/media` to staging

Preserves **hard links** (`-H`), ACLs/xattrs (`-A`/`-X` where supported), numeric owners.

```bash
sudo mkdir -p "$STAGING"

sudo rsync -aHAX --numeric-ids --info=progress2 "${MEDIA_MOUNT}/" "${STAGING}/"
sync

# Second pass (catches changes if anything was still briefly active)
sudo rsync -aHAX --numeric-ids --info=progress2 "${MEDIA_MOUNT}/" "${STAGING}/"
sync
```

**Optional (Btrfs reflinks on restore):** when copying **from staging back onto the new Btrfs** (step 10), you may add **`--reflink=always`** to that `rsync` if your `rsync` supports it — helps space and speed on the new pool. It does not apply to the **first** leg if `/data` is not Btrfs.

---

## 5. Verify staging

```bash
sudo du -x --summarize "${MEDIA_MOUNT}" "$STAGING"
# Expect similar totals; spot-check important directories and files.
```

---

## 6. Unmount old `/media`

```bash
sudo umount "${MEDIA_MOUNT}"
mountpoint "${MEDIA_MOUNT}" && { echo "ERROR: /media still mounted"; exit 1; }
```

---

## 7. Partition each data disk and create the new Btrfs pool

**Erases all of `DISKS`.** Creates one **Linux filesystem** partition per disk, then **RAID0 (data) / RAID1 (metadata)** across members (same idea as `install.sh`).

```bash
set -euo pipefail

need_sgdisk() { command -v sgdisk >/dev/null || sudo pacman -Sy --noconfirm --needed gptfdisk; }
need_sgdisk

for d in "${DISKS[@]}"; do
  sudo sgdisk --zap-all "$d"
  sudo sgdisk -n 1:0:0 -t 1:8300 -c 1:"BTRFS_DATA" "$d"
done
sudo udevadm settle --timeout=30

DATA_PARTS=(/dev/nvme0n1p1 /dev/nvme1n1p1 /dev/nvme2n1p1 /dev/nvme4n1p1)
for p in "${DATA_PARTS[@]}"; do
  [[ -b "$p" ]] || { echo "missing $p"; exit 1; }
  sudo wipefs -af "$p"
done

sudo mkfs.btrfs -f -L "$MEDIA_LABEL" -d raid0 -m raid1 "${DATA_PARTS[@]}"
```

---

## 8. Create `@media` and `@snapshots`

```bash
sudo mkdir -p /mnt/btrfs-top
sudo mount -o subvolid=0 -L "$MEDIA_LABEL" /mnt/btrfs-top

sudo btrfs subvolume create /mnt/btrfs-top/@media
sudo btrfs subvolume create /mnt/btrfs-top/@snapshots

sudo umount /mnt/btrfs-top
sudo rmdir /mnt/btrfs-top
```

---

## 9. Mount new `@media` at a temporary path

```bash
sudo mkdir -p /mnt/newmedia
sudo mount -t btrfs -o "${OPTS},subvol=@media" -L "$MEDIA_LABEL" /mnt/newmedia
```

---

## 10. Restore from `/data/media-staging` → new `@media`

```bash
sudo rsync -aHAX --numeric-ids --info=progress2 "${STAGING}/" /mnt/newmedia/
# Optional on Btrfs dest: add --reflink=always if supported
sync
```

---

## 11. Mount `@snapshots` under the new tree (before switching `/media`)

```bash
sudo mkdir -p /mnt/newmedia/.snapshots
sudo mount -t btrfs -o "${OPTS},subvol=@snapshots" -L "$MEDIA_LABEL" /mnt/newmedia/.snapshots
```

---

## 12. Configure `/etc/fstab` on the installed system

Get the **Btrfs filesystem UUID** (one UUID for the whole multi-device fs):

```bash
sudo btrfs filesystem show -L "$MEDIA_LABEL"
```

Add (replace `<BTRFS_FS_UUID>`):

```fstab
UUID=<BTRFS_FS_UUID>  /media             btrfs  subvol=@media,noatime,compress=zstd:1,space_cache=v2     0 0
UUID=<BTRFS_FS_UUID>  /media/.snapshots  btrfs  subvol=@snapshots,noatime,compress=zstd:1,space_cache=v2  0 0
```

---

## 13. Move production mounts to `/media`

```bash
sudo mkdir -p /media /media/.snapshots

sudo umount /mnt/newmedia/.snapshots
sudo umount /mnt/newmedia

sudo mount -a
mountpoint /media
mountpoint /media/.snapshots
```

If **`mount -a`** fails, fix **`fstab`** before rebooting.

---

## 14. First read-only snapshot (send-ready)

With live data on **`@media`** and **`@snapshots`** mounted at **`/media/.snapshots`**:

```bash
sudo btrfs subvolume snapshot -r /media "/media/.snapshots/$(date +%Y%m%d-%H%M%S)"
sudo btrfs subvolume list -o /media | head
```

---

## 15. Re-enable services

Start SMB/NFS, apps, and containers that use **`/media`**.

---

## 16. Remove staging (only after you trust the new pool)

```bash
# sudo rm -rf /data/media-staging
```

---

## Reference: daily snapshots (optional)

Match **`install.sh`**: install **`/usr/local/bin/btrfs-snapshot-media`**, systemd **`.service`** + **`.timer`**, source **`/media`**, destination **`/media/.snapshots/<timestamp>`**, retention (e.g. keep 7). See **`install.sh`** in this repo for the exact unit and script content.

---

## Troubleshooting

| Issue | What to check |
|--------|----------------|
| `missing …p1` | Re-run `udevadm settle`; confirm DISKS are whole devices and GPT step completed. |
| `mount -a` fails | UUID typo; options typo; mount points must exist (`mkdir /media /media/.snapshots`). |
| Hard links wrong | Both `rsync` legs must include **`-H`**; re-run restore if needed. |
| Wrong disk wiped | Double-check **`DISKS`** against `lsblk` (OS disk must not be listed). |
