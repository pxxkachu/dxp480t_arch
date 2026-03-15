# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, Sonarr, Radarr, Prowlarr, and Tailscale Serve (HTTPS reverse proxy).

All commands assume root (`sudo -i`) unless noted otherwise.

---

## Pre-flight checks

Verify the Btrfs data pool is mounted:

```bash
mountpoint /media
```

If not mounted:

```bash
mount -t btrfs LABEL=media /media
```

Verify internet connectivity:

```bash
curl -sf --max-time 5 https://archlinux.org && echo "OK"
```

---

## 1. Install and authenticate Tailscale

```bash
pacman -S --needed --noconfirm tailscale
systemctl enable --now tailscaled
tailscale up
```

Follow the printed authentication link in a browser.

After authenticating, get your Tailscale IP and FQDN:

```bash
tailscale ip -4
tailscale status --self --json | grep -oP '"DNSName"\s*:\s*"\K[^"]+' | sed 's/\.$//'
```

Note these values — referred to as `<TS_IP>` and `<FQDN>` below.

## 2. Update /etc/hosts

Back up and rewrite. Replace `<HOSTNAME>`, `<TS_IP>`, and `<FQDN>` with your values.

```bash
cp /etc/hosts /etc/hosts.bak
```

```bash
cat <<'EOF' > /etc/hosts
127.0.0.1   localhost
127.0.1.1   <HOSTNAME>.localdomain <HOSTNAME>

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

<TS_IP>     <FQDN> <HOSTNAME>
EOF
```

## 3. Create media group and pre-create arr service accounts

Create the shared media group:

```bash
groupadd media
```

Create sonarr, radarr, and prowlarr accounts **before** installing their AUR packages. The AUR packages ship sysusers files that auto-create these accounts with their own default groups. Pre-creating them with primary group `media` prevents that — sysusers skips users that already exist.

```bash
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media sonarr
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media radarr
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media prowlarr
passwd --lock sonarr
passwd --lock radarr
passwd --lock prowlarr
```

## 4. Install qBittorrent

```bash
pacman -S --needed --noconfirm qbittorrent-nox
```

The package creates a user called `qbt` via sysusers. Fix its primary group to `media`:

```bash
usermod --gid media qbt
passwd --lock qbt
```

## 5. Install paru (AUR helper)

Run as your normal user, not root:

```bash
rm -rf /tmp/paru-bin
git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
cd /tmp/paru-bin
makepkg -si --noconfirm
cd -
rm -rf /tmp/paru-bin
```

## 6. Install Sonarr, Radarr, Prowlarr (AUR)

Run as your normal user, not root:

```bash
paru -S --needed --noconfirm sonarr-bin radarr-bin prowlarr-bin
```

## 7. Add admin user to media group

Switch back to root (`sudo -i`) for the remaining steps.

```bash
usermod -aG media admin
```

Log out and back in after this step for the group membership to take effect.

## 8. Create service data directories

```bash
mkdir -p /var/lib/qbt
chown qbt:media /var/lib/qbt
chmod 775 /var/lib/qbt

mkdir -p /var/lib/sonarr
chown sonarr:media /var/lib/sonarr
chmod 775 /var/lib/sonarr

mkdir -p /var/lib/radarr
chown radarr:media /var/lib/radarr
chmod 775 /var/lib/radarr

mkdir -p /var/lib/prowlarr
chown prowlarr:media /var/lib/prowlarr
chmod 775 /var/lib/prowlarr
```

## 9. Create media directories

```bash
mkdir -p /media/downloads/{pending,complete,torrents}
mkdir -p /media/{movies,shows}

chown qbt:media /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
chown root:media /media/movies /media/shows

chmod 2775 /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
chmod 2775 /media/movies /media/shows
```

The setgid bit (2775) ensures new files inherit the `media` group regardless of which service creates them.

## 10. Configure systemd services

All packages ship their own service files. Use drop-in overrides to set the group and umask without replacing the vendor units — package updates flow through automatically.

### qBittorrent

The package ships a template service (`qbittorrent-nox@.service`). The instance name is the user — `qbittorrent-nox@qbt` runs as user `qbt`. Override the instance to set our group and umask:

```bash
mkdir -p /etc/systemd/system/qbittorrent-nox@qbt.service.d
cat <<'EOF' > /etc/systemd/system/qbittorrent-nox@qbt.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

### Sonarr, Radarr, Prowlarr

```bash
mkdir -p /etc/systemd/system/sonarr.service.d
cat <<'EOF' > /etc/systemd/system/sonarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

```bash
mkdir -p /etc/systemd/system/radarr.service.d
cat <<'EOF' > /etc/systemd/system/radarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

```bash
mkdir -p /etc/systemd/system/prowlarr.service.d
cat <<'EOF' > /etc/systemd/system/prowlarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

## 11. Start all services

```bash
systemctl daemon-reload
systemctl enable --now qbittorrent-nox@qbt sonarr radarr prowlarr
```

Verify they're running:

```bash
systemctl status qbittorrent-nox@qbt sonarr radarr prowlarr
```

Get qBittorrent's initial admin password from its journal:

```bash
journalctl -u qbittorrent-nox@qbt -n 20 | grep -i password
```

## 12. Configure URL bases

The *arr apps need URL bases for Tailscale Serve path-based routing. qBittorrent has no URL base setting, so it gets its own port instead.

Open each web UI directly by IP:

| Service      | Direct URL                  | Setting location                           | Set to           |
|--------------|-----------------------------|------------------------------------------- |------------------|
| Sonarr       | `http://<TS_IP>:8989`       | Settings > General > URL Base              | `/sonarr`        |
| Radarr       | `http://<TS_IP>:7878`       | Settings > General > URL Base              | `/radarr`        |
| Prowlarr     | `http://<TS_IP>:9696`       | Settings > General > URL Base              | `/prowlarr`      |

Restart after changing:

```bash
systemctl restart sonarr radarr prowlarr
```

## 14. Set up Btrfs data SSD

This sets up a single 2.5" SSD at `/data` with a subvolume layout that supports incremental backups via `btrfs send/receive` when a second SSD is added later.

### Identify the SSD

```bash
lsblk -dpno NAME,SIZE,MODEL
```

Replace `/dev/sdX` below with the actual device (e.g., `/dev/sde`).

### Partition and format

```bash
sgdisk --zap-all /dev/sdX
sgdisk -n 1:0:0 -t 1:8300 -c 1:"DATA" /dev/sdX
udevadm settle --timeout=10
mkfs.btrfs -f -L data /dev/sdX1
```

### Create subvolume layout

Btrfs send/receive operates on subvolumes, not filesystems. This layout must exist before any data is written.

```bash
mkdir -p /mnt/temp
mount /dev/sdX1 /mnt/temp
btrfs subvolume create /mnt/temp/@data
btrfs subvolume create /mnt/temp/@snapshots
umount /mnt/temp
rmdir /mnt/temp
```

- `@data` — live data subvolume, mounted at `/data`
- `@snapshots` — holds read-only snapshots for send/receive

### Mount subvolumes

```bash
mkdir -p /data /data/.snapshots
mount -o noatime,compress=zstd:1,subvol=@data LABEL=data /data
mount -o noatime,compress=zstd:1,subvol=@snapshots LABEL=data /data/.snapshots
```

### Add to fstab

```bash
cat >> /etc/fstab <<'FSTAB'

# Btrfs data SSD
LABEL=data  /data             btrfs  noatime,compress=zstd:1,subvol=@data       0 0
LABEL=data  /data/.snapshots  btrfs  noatime,compress=zstd:1,subvol=@snapshots  0 0
FSTAB
```

Verify:

```bash
umount /data/.snapshots
umount /data
mount -a
mountpoint /data
mountpoint /data/.snapshots
```

### Create snapshot script

```bash
cat > /usr/local/bin/btrfs-snapshot-data << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

SNAP_DIR="/data/.snapshots"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
KEEP=7

btrfs subvolume snapshot -r /data "${SNAP_DIR}/${TIMESTAMP}"
echo "Created snapshot: ${SNAP_DIR}/${TIMESTAMP}"

mapfile -t ALL < <(ls -1d "${SNAP_DIR}"/2* 2>/dev/null | sort)
if (( ${#ALL[@]} > KEEP )); then
  DELETE=("${ALL[@]:0:${#ALL[@]}-KEEP}")
  for snap in "${DELETE[@]}"; do
    btrfs subvolume delete "$snap"
    echo "Deleted old snapshot: $snap"
  done
fi
SCRIPT
chmod +x /usr/local/bin/btrfs-snapshot-data
```

Test it:

```bash
btrfs-snapshot-data
ls /data/.snapshots/
```

### Create systemd timer for daily snapshots

```bash
cat > /etc/systemd/system/btrfs-snapshot-data.service << 'EOF'
[Unit]
Description=Btrfs snapshot of /data

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot-data
EOF

cat > /etc/systemd/system/btrfs-snapshot-data.timer << 'EOF'
[Unit]
Description=Daily Btrfs snapshot of /data

[Timer]
OnCalendar=daily
AccuracySec=1h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now btrfs-snapshot-data.timer
```

Verify the timer is active:

```bash
systemctl list-timers btrfs-snapshot-data.timer
```

## 15. (Future) Add backup SSD with btrfs send/receive

When the second SSD arrives, format it, do an initial full send, then incremental sends going forward.

### Format and create matching subvolumes

```bash
sgdisk --zap-all /dev/sdY
sgdisk -n 1:0:0 -t 1:8300 -c 1:"DATABACKUP" /dev/sdY
udevadm settle --timeout=10
mkfs.btrfs -f -L databackup /dev/sdY1

mkdir -p /mnt/temp
mount /dev/sdY1 /mnt/temp
btrfs subvolume create /mnt/temp/@data
btrfs subvolume create /mnt/temp/@snapshots
umount /mnt/temp
rmdir /mnt/temp
```

### Mount the backup drive

```bash
mkdir -p /backup /backup/.snapshots
mount -o noatime,compress=zstd:1,subvol=@data LABEL=databackup /backup
mount -o noatime,compress=zstd:1,subvol=@snapshots LABEL=databackup /backup/.snapshots
```

Add to fstab:

```bash
cat >> /etc/fstab <<'FSTAB'

# Btrfs backup SSD
LABEL=databackup  /backup             btrfs  noatime,compress=zstd:1,subvol=@data       0 0
LABEL=databackup  /backup/.snapshots  btrfs  noatime,compress=zstd:1,subvol=@snapshots  0 0
FSTAB
```

### Initial full send

```bash
LATEST=$(ls -1d /data/.snapshots/2* | sort | tail -1)
btrfs send "$LATEST" | btrfs receive /backup/.snapshots/
echo "Full send complete: $LATEST"
```

### Incremental sends

After the initial send, subsequent backups only transfer the delta:

```bash
PREV=<previous snapshot name>
LATEST=$(ls -1d /data/.snapshots/2* | sort | tail -1)
btrfs send -p "/data/.snapshots/${PREV}" "$LATEST" | btrfs receive /backup/.snapshots/
```

### Create automated backup script

```bash
cat > /usr/local/bin/btrfs-backup-data << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

SRC="/data/.snapshots"
DST="/backup/.snapshots"

if ! mountpoint -q /backup; then
  echo "ERROR: /backup is not mounted"
  exit 1
fi

LATEST=$(ls -1d "${SRC}"/2* 2>/dev/null | sort | tail -1)
if [[ -z "$LATEST" ]]; then
  echo "ERROR: No snapshots found in ${SRC}"
  exit 1
fi

LATEST_NAME=$(basename "$LATEST")

if [[ -d "${DST}/${LATEST_NAME}" ]]; then
  echo "Backup already up to date: ${LATEST_NAME}"
  exit 0
fi

PREV_ON_DST=$(ls -1d "${DST}"/2* 2>/dev/null | sort | tail -1)

if [[ -z "$PREV_ON_DST" ]]; then
  echo "No previous backup found — doing full send"
  btrfs send "$LATEST" | btrfs receive "$DST"
else
  PREV_NAME=$(basename "$PREV_ON_DST")
  echo "Incremental send: ${PREV_NAME} -> ${LATEST_NAME}"
  btrfs send -p "${SRC}/${PREV_NAME}" "$LATEST" | btrfs receive "$DST"
fi

echo "Backup complete: ${LATEST_NAME}"
SCRIPT
chmod +x /usr/local/bin/btrfs-backup-data
```

### Automate with a timer

```bash
cat > /etc/systemd/system/btrfs-backup-data.service << 'EOF'
[Unit]
Description=Btrfs incremental backup of /data to /backup
After=data.mount backup.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-backup-data
EOF

cat > /etc/systemd/system/btrfs-backup-data.timer << 'EOF'
[Unit]
Description=Daily Btrfs backup of /data

[Timer]
OnCalendar=*-*-* 02:00:00
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now btrfs-backup-data.timer
```
