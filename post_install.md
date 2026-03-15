# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, Sonarr, Radarr, Prowlarr, and Tailscale Serve (HTTPS reverse proxy).

All commands include `sudo` where needed — copy and paste directly into your terminal as your normal user. Steps 5 and 6 **must not** use sudo (AUR packages must be built as a normal user).

---

## Pre-flight checks

Verify the Btrfs data pool is mounted:

```bash
mountpoint /media
```

If not mounted:

```bash
sudo mount -t btrfs LABEL=media /media
```

Verify internet connectivity:

```bash
curl -sf --max-time 5 https://archlinux.org && echo "OK"
```

---

## 1. Install and authenticate Tailscale

```bash
sudo pacman -S --needed --noconfirm tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Follow the printed authentication link in a browser.

After authenticating, get your Tailscale IP and FQDN:

```bash
tailscale ip -4
tailscale status --self --json | grep -oP '"DNSName"\s*:\s*"\K[^"]+' | sed 's/\.$//'
```

Note these values — referred to as `<TS_IP>` and `<FQDN>` below.

## 2. Update /etc/hosts

Back up and rewrite. Replace `<HOSTNAME>`, `<TS_IP>`, and `<FQDN>` with your actual values before running:

```bash
sudo cp /etc/hosts /etc/hosts.bak
```

```bash
sudo tee /etc/hosts > /dev/null <<'EOF'
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
sudo groupadd media
```

Create sonarr, radarr, and prowlarr accounts **before** installing their AUR packages. The AUR packages ship sysusers files that auto-create these accounts with their own default groups. Pre-creating them with primary group `media` prevents that — sysusers skips users that already exist.

```bash
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media sonarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media radarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media prowlarr
sudo passwd --lock sonarr
sudo passwd --lock radarr
sudo passwd --lock prowlarr
```

## 4. Install qBittorrent

```bash
sudo pacman -S --needed --noconfirm qbittorrent-nox
```

The package creates a user called `qbt` via sysusers. Fix its primary group to `media`:

```bash
sudo usermod --gid media qbt
sudo passwd --lock qbt
```

## 5. Install paru (AUR helper)

**Run as your normal user — do NOT use sudo:**

```bash
rm -rf /tmp/paru-git
git clone https://aur.archlinux.org/paru-git.git /tmp/paru-git
cd /tmp/paru-git
makepkg -si --noconfirm
cd -
rm -rf /tmp/paru-git
```

## 6. Install Sonarr, Radarr, Prowlarr (AUR)

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed --noconfirm sonarr-bin radarr-bin prowlarr-bin
```

## 7. Add admin user to media group

```bash
sudo usermod -aG media admin
```

Log out and back in after this step for the group membership to take effect.

## 8. Create service data directories

```bash
sudo mkdir -p /var/lib/qbt
sudo chown qbt:media /var/lib/qbt
sudo chmod 775 /var/lib/qbt

sudo mkdir -p /var/lib/sonarr
sudo chown sonarr:media /var/lib/sonarr
sudo chmod 775 /var/lib/sonarr

sudo mkdir -p /var/lib/radarr
sudo chown radarr:media /var/lib/radarr
sudo chmod 775 /var/lib/radarr

sudo mkdir -p /var/lib/prowlarr
sudo chown prowlarr:media /var/lib/prowlarr
sudo chmod 775 /var/lib/prowlarr
```

## 9. Create media directories

```bash
sudo mkdir -p /media/downloads/{pending,complete,torrents}
sudo mkdir -p /media/{movies,shows}

sudo chown qbt:media /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
sudo chown root:media /media/movies /media/shows

sudo chmod 2775 /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
sudo chmod 2775 /media/movies /media/shows
```

The setgid bit (2775) ensures new files inherit the `media` group regardless of which service creates them.

## 10. Configure systemd services

All packages ship their own service files. Use drop-in overrides to set the group and umask without replacing the vendor units — package updates flow through automatically.

### qBittorrent

The package ships a template service (`qbittorrent-nox@.service`). The instance name is the user — `qbittorrent-nox@qbt` runs as user `qbt`. Override the instance to set our group and umask:

```bash
sudo mkdir -p /etc/systemd/system/qbittorrent-nox@qbt.service.d
sudo tee /etc/systemd/system/qbittorrent-nox@qbt.service.d/override.conf > /dev/null <<'EOF'
[Service]
Group=media
UMask=002
EOF
```

### Sonarr, Radarr, Prowlarr

```bash
sudo mkdir -p /etc/systemd/system/sonarr.service.d
sudo tee /etc/systemd/system/sonarr.service.d/override.conf > /dev/null <<'EOF'
[Service]
Group=media
UMask=002
EOF
```

```bash
sudo mkdir -p /etc/systemd/system/radarr.service.d
sudo tee /etc/systemd/system/radarr.service.d/override.conf > /dev/null <<'EOF'
[Service]
Group=media
UMask=002
EOF
```

```bash
sudo mkdir -p /etc/systemd/system/prowlarr.service.d
sudo tee /etc/systemd/system/prowlarr.service.d/override.conf > /dev/null <<'EOF'
[Service]
Group=media
UMask=002
EOF
```

## 11. Install and configure Plex Media Server

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed --noconfirm plex-media-server
```

The package creates a `plex` user. Add it to the `media` group so it can read media files:

```bash
sudo usermod -aG media plex
```

Create the Plex data directory with correct ownership:

```bash
sudo mkdir -p /var/lib/plex
sudo chown plex:plex /var/lib/plex
sudo chmod 755 /var/lib/plex
```

Add a drop-in override for the media group and umask (same pattern as other services):

```bash
sudo mkdir -p /etc/systemd/system/plexmediaserver.service.d
sudo tee /etc/systemd/system/plexmediaserver.service.d/override.conf > /dev/null <<'EOF'
[Service]
UMask=002
EOF
```

## 12. Start all services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qbittorrent-nox@qbt sonarr radarr prowlarr plexmediaserver
```

Verify they're running:

```bash
systemctl status qbittorrent-nox@qbt sonarr radarr prowlarr plexmediaserver
```

Get qBittorrent's initial admin password from its journal:

```bash
sudo journalctl -u qbittorrent-nox@qbt -n 20 | grep -i password
```

## 13. Access services

All services are accessible from any device on your Tailscale network using the Tailscale IP:

| Service      | URL                         |
|--------------|-----------------------------|
| qBittorrent  | `http://<TS_IP>:8080`       |
| Sonarr       | `http://<TS_IP>:8989`       |
| Radarr       | `http://<TS_IP>:7878`       |
| Prowlarr     | `http://<TS_IP>:9696`       |
| Plex         | `http://<TS_IP>:32400/web`  |

Since Tailscale encrypts all traffic between devices (WireGuard), HTTPS is not required for services accessed within the tailnet.

On first access, Plex requires initial setup from a browser on the same network. Visit `http://<TS_IP>:32400/web` and sign in with your Plex account. Under Settings > Libraries, add your media folders (`/media/movies`, `/media/shows`).

## 14. Set up Btrfs data SSD

This sets up a single 2.5" SSD at `/data` with a subvolume layout that supports incremental backups via `btrfs send/receive` when a second SSD is added later.

### Identify the SSD

```bash
lsblk -dpno NAME,SIZE,MODEL
```

Replace `/dev/sdX` below with the actual device (e.g., `/dev/sde`).

### Partition and format

`sfdisk` is used here instead of `sgdisk` since it ships with `util-linux` (always installed).

```bash
sudo wipefs -af /dev/sdX
echo 'label: gpt
type=linux' | sudo sfdisk /dev/sdX
sudo udevadm settle --timeout=10
sudo mkfs.btrfs -f -L data /dev/sdX1
```

### Create subvolume layout

Btrfs send/receive operates on subvolumes, not filesystems. This layout must exist before any data is written.

```bash
sudo mkdir -p /mnt/temp
sudo mount /dev/sdX1 /mnt/temp
sudo btrfs subvolume create /mnt/temp/@data
sudo btrfs subvolume create /mnt/temp/@snapshots
sudo umount /mnt/temp
sudo rmdir /mnt/temp
```

- `@data` — live data subvolume, mounted at `/data`
- `@snapshots` — holds read-only snapshots for send/receive

### Mount subvolumes

Mount `@data` first, create the `.snapshots` directory inside it, then mount `@snapshots` over it:

```bash
sudo mkdir -p /data
sudo mount -o noatime,compress=zstd:1,subvol=@data LABEL=data /data
sudo mkdir -p /data/.snapshots
sudo mount -o noatime,compress=zstd:1,subvol=@snapshots LABEL=data /data/.snapshots
```

### Add to fstab

```bash
sudo tee -a /etc/fstab > /dev/null <<'FSTAB'

# Btrfs data SSD
LABEL=data  /data             btrfs  noatime,compress=zstd:1,subvol=@data       0 0
LABEL=data  /data/.snapshots  btrfs  noatime,compress=zstd:1,subvol=@snapshots  0 0
FSTAB
```

Verify fstab works (the `.snapshots` dir persists inside `@data` so `mount -a` will find it):

```bash
sudo umount /data/.snapshots
sudo umount /data
sudo mount -a
mountpoint /data
mountpoint /data/.snapshots
```

### Create snapshot script

```bash
sudo tee /usr/local/bin/btrfs-snapshot-data > /dev/null << 'SCRIPT'
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
sudo chmod +x /usr/local/bin/btrfs-snapshot-data
```

Test it:

```bash
sudo btrfs-snapshot-data
ls /data/.snapshots/
```

### Create systemd timer for daily snapshots

```bash
sudo tee /etc/systemd/system/btrfs-snapshot-data.service > /dev/null << 'EOF'
[Unit]
Description=Btrfs snapshot of /data

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot-data
EOF

sudo tee /etc/systemd/system/btrfs-snapshot-data.timer > /dev/null << 'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-snapshot-data.timer
```

Verify the timer is active:

```bash
systemctl list-timers btrfs-snapshot-data.timer
```

## 15. (Future) Add backup SSD with btrfs send/receive

When the second SSD arrives, format it, do an initial full send, then incremental sends going forward.

### Format and create matching subvolumes

Replace `/dev/sdY` with the actual device.

```bash
sudo wipefs -af /dev/sdY
echo 'label: gpt
type=linux' | sudo sfdisk /dev/sdY
sudo udevadm settle --timeout=10
sudo mkfs.btrfs -f -L databackup /dev/sdY1

sudo mkdir -p /mnt/temp
sudo mount /dev/sdY1 /mnt/temp
sudo btrfs subvolume create /mnt/temp/@data
sudo btrfs subvolume create /mnt/temp/@snapshots
sudo umount /mnt/temp
sudo rmdir /mnt/temp
```

### Mount the backup drive

```bash
sudo mkdir -p /backup /backup/.snapshots
sudo mount -o noatime,compress=zstd:1,subvol=@data LABEL=databackup /backup
sudo mount -o noatime,compress=zstd:1,subvol=@snapshots LABEL=databackup /backup/.snapshots
```

Add to fstab:

```bash
sudo tee -a /etc/fstab > /dev/null <<'FSTAB'

# Btrfs backup SSD
LABEL=databackup  /backup             btrfs  noatime,compress=zstd:1,subvol=@data       0 0
LABEL=databackup  /backup/.snapshots  btrfs  noatime,compress=zstd:1,subvol=@snapshots  0 0
FSTAB
```

### Initial full send

```bash
LATEST=$(ls -1d /data/.snapshots/2* | sort | tail -1)
sudo btrfs send "$LATEST" | sudo btrfs receive /backup/.snapshots/
echo "Full send complete: $LATEST"
```

### Incremental sends

After the initial send, subsequent backups only transfer the delta:

```bash
PREV="<previous snapshot name>"
LATEST=$(ls -1d /data/.snapshots/2* | sort | tail -1)
sudo btrfs send -p "/data/.snapshots/${PREV}" "$LATEST" | sudo btrfs receive /backup/.snapshots/
```

### Create automated backup script

```bash
sudo tee /usr/local/bin/btrfs-backup-data > /dev/null << 'SCRIPT'
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
sudo chmod +x /usr/local/bin/btrfs-backup-data
```

### Automate with a timer

```bash
sudo tee /etc/systemd/system/btrfs-backup-data.service > /dev/null << 'EOF'
[Unit]
Description=Btrfs incremental backup of /data to /backup
After=data.mount backup.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-backup-data
EOF

sudo tee /etc/systemd/system/btrfs-backup-data.timer > /dev/null << 'EOF'
[Unit]
Description=Daily Btrfs backup of /data

[Timer]
OnCalendar=*-*-* 02:00:00
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-backup-data.timer
```
