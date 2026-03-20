# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, Sonarr, Radarr, Prowlarr, Recyclarr, and Tailscale Serve (HTTPS reverse proxy).

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

---

## 1. Install and authenticate Tailscale

```bash
sudo pacman -S tailscale
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

```bash
sudo nano /etc/hosts

127.0.0.1   localhost
127.0.1.1   <HOSTNAME>.localdomain <HOSTNAME>

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

<TS_IP>     <FQDN> <HOSTNAME>
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
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media plex
sudo passwd --lock sonarr
sudo passwd --lock radarr
sudo passwd --lock prowlarr
sudo passwd --lock plex
```

## 4. Install qBittorrent

```bash
sudo pacman -S qbittorrent-nox
```

The package creates a user called `qbt` via sysusers. Fix its primary group to `media`:

```bash
sudo usermod --gid media qbt
sudo passwd --lock qbt
```

## 5. Install paru (AUR helper)

**Run as your normal user — do NOT use sudo:**

```bash
git clone https://aur.archlinux.org/paru-git.git /tmp/paru-git
cd /tmp/paru-git
makepkg -si --noconfirm
cd -
rm -rf /tmp/paru-git
```

## 6. Install Sonarr, Radarr, Prowlarr (AUR)

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed sonarr-bin radarr-bin prowlarr-bin
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
sudo chown radarr:media /media/movies
sudo chown sonarr:media /media/shows

sudo chmod 2775 /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents /media/movies /media/shows
```

The setgid bit (2775) ensures new files inherit the `media` group regardless of which service creates them.

## 10. Configure systemd services

All packages ship their own service files. Use drop-in overrides to set the group and umask without replacing the vendor units — package updates flow through automatically.

### qBittorrent

The package ships a template service (`qbittorrent-nox@.service`). The instance name is the user — `qbittorrent-nox@qbt` runs as user `qbt`. Override the instance to set our group and umask:

```bash
sudo mkdir -p /etc/systemd/system/qbittorrent-nox@qbt.service.d
sudo nano /etc/systemd/system/qbittorrent-nox@qbt.service.d/override.conf

[Service]
Group=media
UMask=002
```

### Sonarr, Radarr, Prowlarr

```bash
sudo mkdir -p /etc/systemd/system/sonarr.service.d
sudo nano /etc/systemd/system/sonarr.service.d/override.conf

[Service]
Group=media
UMask=002
```

```bash
sudo mkdir -p /etc/systemd/system/radarr.service.d
sudo nano /etc/systemd/system/radarr.service.d/override.conf

[Service]
Group=media
UMask=002
```

```bash
sudo mkdir -p /etc/systemd/system/prowlarr.service.d
sudo nano /etc/systemd/system/prowlarr.service.d/override.conf

[Service]
Group=media
UMask=002
```

## 11. Install and configure Plex Media Server

**Run as your normal user — do NOT use sudo:**

```bash
paru -S plex-media-server
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
sudo nano /etc/systemd/system/plexmediaserver.service.d/override.conf

[Service]
Group=media
UMask=002
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
| autobrr      | `http://<TS_IP>:7474`       |

## 14. Install and configure cross-seed

cross-seed automatically finds matching torrents across your indexers based on your existing library and injects them into qBittorrent for cross-seeding. It runs as a headless daemon (API-only on port 2468, no web UI).

Create a system user for cross-seed:

```bash
sudo useradd --system --home-dir /var/lib/cross-seed --shell /usr/bin/nologin --gid media crossseed
sudo passwd --lock crossseed
sudo mkdir -p /var/lib/cross-seed
sudo chown crossseed:media /var/lib/cross-seed
sudo chmod 750 /var/lib/cross-seed
```

**Run as your normal user — do NOT use sudo:**

```bash
paru -S nodejs-cross-seed
```

Generate the default configuration:

```bash
sudo -u crossseed -H cross-seed gen-config
```

This creates `/var/lib/cross-seed/.cross-seed/config.js`. Edit it to connect to qBittorrent and your Torznab indexers (from Prowlarr):

```bash
sudo nano /var/lib/cross-seed/.cross-seed/config.js
```

Key settings to configure:

| Setting | Example value |
|---------|---------------|
| `torrentClients` | `["qbittorrent:http://user:pass@localhost:8080"]` |
| `torznab` | `["http://localhost:9696/1/api?apikey=YOUR_KEY", ...]` (copy from Prowlarr under each indexer) |
| `linkDirs` | `["/media/downloads/complete"]` (optional, enables hardlinking) |

Refer to the [cross-seed docs](https://cross-seed.org/docs/basics/getting-started) for all available options. If you skip `linkDirs`, cross-seed will tell you which config values to adjust.

Create the systemd service:

```bash
sudo nano /etc/systemd/system/cross-seed.service

[Unit]
Description=cross-seed daemon
After=network-online.target

[Service]
Type=simple
User=crossseed
Group=media
Environment=HOME=/var/lib/cross-seed
ExecStart=/usr/bin/cross-seed daemon
Restart=on-failure
RestartSec=10
UMask=002

[Install]
WantedBy=multi-user.target
```

Start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cross-seed
systemctl status cross-seed
```

Check logs with:

```bash
sudo journalctl -u cross-seed -f
```

## 15. Install and configure autobrr

autobrr monitors IRC announce channels and RSS feeds to automatically grab new releases and push them to qBittorrent. It provides a web UI on port 7474.

Create a system user for autobrr:

```bash
sudo useradd --system --home-dir /var/lib/autobrr --shell /usr/bin/nologin --gid media autobrr
sudo passwd --lock autobrr
sudo mkdir -p /var/lib/autobrr
sudo chown autobrr:media /var/lib/autobrr
sudo chmod 750 /var/lib/autobrr
```

**Run as your normal user — do NOT use sudo:**

```bash
paru -S autobrr
```

Pre-create the config so autobrr listens on all interfaces (needed for Tailscale access). First generate a random session secret:

```bash
head /dev/urandom | tr -dc A-Za-z0-9 | head -c32; echo
```

Copy the output, then create the config:

```bash
sudo nano /var/lib/autobrr/config.toml

host = "0.0.0.0"
port = 7474
sessionSecret = "<paste your generated secret>"
```

Create the systemd service:

```bash
sudo nano /etc/systemd/system/autobrr.service

[Unit]
Description=autobrr service
After=network-online.target

[Service]
Type=simple
User=autobrr
Group=media
ExecStart=/usr/bin/autobrr --config=/var/lib/autobrr
Restart=on-failure
RestartSec=10
UMask=002

[Install]
WantedBy=multi-user.target
```

Start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now autobrr
systemctl status autobrr
```

Visit `http://<TS_IP>:7474` to create your initial admin account. Under Settings > Download Clients, add qBittorrent at `http://localhost:8080`.

## 16. Install and configure Recyclarr

Recyclarr automatically syncs TRaSH Guide quality profiles, custom formats, and media naming settings to Sonarr and Radarr. It runs as a periodic one-shot via a systemd timer (no web UI).

Create a system user for Recyclarr:

```bash
sudo useradd --system --home-dir /var/lib/recyclarr --shell /usr/bin/nologin --gid media recyclarr
sudo passwd --lock recyclarr
sudo mkdir -p /var/lib/recyclarr
sudo chown recyclarr:media /var/lib/recyclarr
sudo chmod 750 /var/lib/recyclarr
```

**Run as your normal user — do NOT use sudo:**

```bash
paru -S recyclarr-bin
```

List available TRaSH Guide quality profile templates:

```bash
sudo -u recyclarr RECYCLARR_APP_DATA=/var/lib/recyclarr recyclarr config list templates
```

Generate config files from templates. Pick the profiles that match your setup (e.g., `hd-bluray-web` for 1080p movies, `web-1080p` for TV):

```bash
sudo -u recyclarr RECYCLARR_APP_DATA=/var/lib/recyclarr recyclarr config create --template hd-bluray-web
sudo -u recyclarr RECYCLARR_APP_DATA=/var/lib/recyclarr recyclarr config create --template web-1080p
```

This creates config files in `/var/lib/recyclarr/configs/`. Edit each one with your instance URL and API key (Settings → General → Security in Sonarr/Radarr):

```bash
sudo nano /var/lib/recyclarr/configs/hd-bluray-web.yml
```

Update `base_url` and `api_key`:

```yaml
radarr:
  hd-bluray-web:
    base_url: http://localhost:7878
    api_key: <your_radarr_api_key>
    delete_old_custom_formats: true
```

```bash
sudo nano /var/lib/recyclarr/configs/web-1080p.yml
```

```yaml
sonarr:
  web-1080p:
    base_url: http://localhost:8989
    api_key: <your_sonarr_api_key>
    delete_old_custom_formats: true
```

Optionally, store API keys in a secrets file:

```bash
sudo nano /var/lib/recyclarr/secrets.yml

radarr_url: http://localhost:7878
radarr_apikey: <your_radarr_api_key>
sonarr_url: http://localhost:8989
sonarr_apikey: <your_sonarr_api_key>
```

Then reference them in config files with `!secret radarr_url`, `!secret radarr_apikey`, etc.

Fix ownership after editing configs (nano runs as root via sudo):

```bash
sudo chown -R recyclarr:media /var/lib/recyclarr
```

Run the first sync to import TRaSH Guide settings:

```bash
sudo -u recyclarr RECYCLARR_APP_DATA=/var/lib/recyclarr recyclarr sync
```

Verify in Sonarr/Radarr under Settings → Custom Formats and Settings → Profiles that the new quality profiles and custom formats appear.

Create the systemd service and timer for daily syncs:

```bash
sudo nano /etc/systemd/system/recyclarr.service

[Unit]
Description=Recyclarr TRaSH Guides sync
After=network-online.target sonarr.service radarr.service
Wants=network-online.target

[Service]
Type=oneshot
User=recyclarr
Group=media
Environment=RECYCLARR_APP_DATA=/var/lib/recyclarr
ExecStart=/usr/bin/recyclarr sync
```

```bash
sudo nano /etc/systemd/system/recyclarr.timer

[Unit]
Description=Run Recyclarr sync daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

Start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now recyclarr.timer
```

Verify with:

```bash
systemctl list-timers recyclarr.timer
sudo journalctl -u recyclarr.service
```

## 17. Set up Caddy for HTTPS (optional)

Caddy acts as a reverse proxy with automatic HTTPS using Tailscale-issued certificates. This eliminates browser security warnings and enables secure-context browser features (clipboard, service workers, etc.). Traffic over Tailscale is already encrypted via WireGuard — Caddy adds a second TLS layer that the browser recognises as secure.

Since Caddy 2.5+, it natively fetches certificates from the local Tailscale daemon for `*.ts.net` domains with no manual certificate management.

Plex handles its own TLS certificates (via `plex.direct`), and cross-seed has no web UI, so neither needs Caddy.

### Install Caddy

```bash
sudo pacman -S caddy
```

### Grant Caddy permission to fetch Tailscale certificates

Caddy runs as the `caddy` user, which needs access to the Tailscale daemon socket to request certificates. Add the following line to the tailscaled environment file:

```bash
sudo nano /etc/default/tailscaled

TS_PERMIT_CERT_UID=caddy
```

Restart the Tailscale daemon to pick up the change:

```bash
sudo systemctl restart tailscaled
```

### Enable HTTPS certificates in your tailnet

In the [Tailscale admin console](https://login.tailscale.com/admin/dns), make sure **HTTPS Certificates** is enabled under DNS settings. This allows machines to request Let's Encrypt certificates for their `*.ts.net` hostnames.

### Configure the Caddyfile

Replace `<FQDN>` below with your machine's full Tailscale hostname (e.g., `nas.tailnet-name.ts.net`). Get it with:

```bash
tailscale status --self --json | grep -oP '"DNSName"\s*:\s*"\K[^"]+' | sed 's/\.$//'
```

Edit the Caddyfile:

```bash
sudo nano /etc/caddy/Caddyfile

<FQDN>:10443 {
    reverse_proxy 127.0.0.1:8080
}

<FQDN>:10444 {
    reverse_proxy 127.0.0.1:8989
}

<FQDN>:10445 {
    reverse_proxy 127.0.0.1:7878
}

<FQDN>:10446 {
    reverse_proxy 127.0.0.1:9696
}

<FQDN>:10447 {
    reverse_proxy 127.0.0.1:7474
}
```

### Start Caddy

```bash
sudo systemctl enable --now caddy
systemctl status caddy
```

Caddy automatically fetches a Tailscale certificate on the first HTTPS request to each port. Certificates are valid for 90 days and renew automatically.

Check logs if anything goes wrong:

```bash
sudo journalctl -u caddy -f
```

### HTTPS access

| Service     | HTTPS URL                               |
|-------------|-----------------------------------------|
| qBittorrent | `https://<FQDN>:10443`                 |
| Sonarr      | `https://<FQDN>:10444`                 |
| Radarr      | `https://<FQDN>:10445`                 |
| Prowlarr    | `https://<FQDN>:10446`                 |
| autobrr     | `https://<FQDN>:10447`                 |
| Plex        | `https://<FQDN>:32400/web` (own TLS)   |

The HTTP URLs from step 13 continue to work alongside HTTPS. To enforce HTTPS-only, bind each service to `127.0.0.1` in its own settings so it is only reachable through Caddy.

## 18. Set up Btrfs data SSD

This sets up a single 2.5" SSD at `/data` with a subvolume layout that supports incremental backups via `btrfs send/receive` when a second SSD is added later.

Replace `/dev/sdX` below with the actual device (e.g., `/dev/sde`).

### Partition and format

```bash
# Wipe existing signatures to ensure a clean start
sudo wipefs -a /dev/sda

# Create the Btrfs filesystem with the label "data"
sudo mkfs.btrfs -f -L data /dev/sda
```

### Create subvolume layout

```bash
# Create a temporary mount point and mount the drive root
sudo mkdir -p /mnt/tmp_root
sudo mount /dev/sda /mnt/tmp_root

# Create subvolumes for your data and your snapshots
# Using '@' is a common convention to identify top-level subvolumes
sudo btrfs subvolume create /mnt/tmp_root/@data
sudo btrfs subvolume create /mnt/tmp_root/@snapshots

# Clean up temporary mount
sudo umount /mnt/tmp_root
```

### Mount subvolumes

```bash
# Create the permanent mount point
sudo mkdir -p /data

# Mount the @data subvolume
sudo mount -o noatime,compress=zstd:1,subvol=@data /dev/sda /data

# Inside your data subvolume, create a folder to access your snapshots
sudo mkdir -p /data/.snapshots

# Mount the @snapshots subvolume into that folder
sudo mount -o noatime,compress=zstd:1,subvol=@snapshots /dev/sda /data/.snapshots
```

### Add to fstab

```bash
sudo nano /etc/fstab

# data
UUID=<drive uuid>  /data             btrfs  noatime,compress=zstd:1,subvol=@data       0 0
UUID=<drive uuid>  /data/.snapshots  btrfs  noatime,compress=zstd:1,subvol=@snapshots  0 0
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
sudo nano /usr/local/bin/daily-data-snapshot.sh

#!/usr/bin/env bash
set -euo pipefail

# CONFIGURATION
# Add your source and snapshot pairs to this associative array
declare -A TARGETS=(
    ["/data"]="/data/.snapshots"
    ["/media"]="/media/.snapshots"
)

TIMESTAMP=$(date +%Y-%m-%d)
KEEP=14

# Loop through each source directory
for SOURCE_SUBVOL in "${!TARGETS[@]}"; do
    SNAP_DIR="${TARGETS[$SOURCE_SUBVOL]}"
    
    echo "--- Processing: $SOURCE_SUBVOL ---"

    # 1. Create a new read-only snapshot
    if [ ! -d "${SNAP_DIR}/${TIMESTAMP}" ]; then
        # Ensure the snapshot directory exists
        mkdir -p "$SNAP_DIR"
        btrfs subvolume snapshot -r "$SOURCE_SUBVOL" "${SNAP_DIR}/${TIMESTAMP}"
        echo "Created daily snapshot for $SOURCE_SUBVOL: ${TIMESTAMP}"
    else
        echo "Snapshot for ${TIMESTAMP} already exists on $SOURCE_SUBVOL. Skipping."
    fi

    # 2. Cleanup old snapshots
    mapfile -t ALL_SNAPS < <(ls -1d "${SNAP_DIR}"/20* 2>/dev/null | sort)

    if (( ${#ALL_SNAPS[@]} > KEEP )); then
        NUM_TO_DELETE=$(( ${#ALL_SNAPS[@]} - KEEP ))
        DELETION_LIST=("${ALL_SNAPS[@]:0:NUM_TO_DELETE}")
        
        for old_snap in "${DELETION_LIST[@]}"; do
            echo "Deleting old snapshot: $old_snap"
            btrfs subvolume delete "$old_snap"
        done
    fi
done

# 2. Cleanup old snapshots
# List snapshots in the directory, sort them, and identify which to delete
mapfile -t ALL_SNAPS < <(ls -1d "${SNAP_DIR}"/20* 2>/dev/null | sort)

if (( ${#ALL_SNAPS[@]} > KEEP )); then
    # Calculate how many to delete to keep exactly $KEEP
    NUM_TO_DELETE=$(( ${#ALL_SNAPS[@]} - KEEP ))
    DELETION_LIST=("${ALL_SNAPS[@]:0:NUM_TO_DELETE}")
    
    for old_snap in "${DELETION_LIST[@]}"; do
        echo "Deleting old snapshot: $old_snap"
        btrfs subvolume delete "$old_snap"
    done
fi
```
CHMOD it:

```bash
sudo chmod +x /usr/local/bin/daily-data-snapshot.sh
```

Test it:

```bash
sudo /usr/local/bin/daily-data-snapshot.sh
ls /data/.snapshots/
```

### Create systemd timer and service for daily snapshots

```bash
# Service
sudo nano /etc/systemd/system/daily-data-snapshot.service

[Unit]
Description=Daily Data Snapshot
Requires=data.mount
After=data.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-data-snapshot.sh
# Runs the script with lower priority so it doesn't slow down the PC
Nice=19
IOSchedulingClass=idle

# Timer
sudo nano /etc/systemd/system/daily-data-snapshot.timer

[Unit]
Description=Create daily data snapshots

[Timer]
# Run every day at 12:00 AM
OnCalendar=daily
# If the PC was off at midnight, run it immediately on boot
Persistent=true

[Install]
WantedBy=timers.target

# Enable timer
sudo systemctl daemon-reload
sudo systemctl enable --now daily-data-snapshot.timer

# Verify timer is active
systemctl list-timers daily-data-snapshot.timer
```

## 19. (Future) Add backup SSD with btrfs send/receive

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
sudo mkdir -p /backup
sudo mount -o noatime,compress=zstd:1,subvol=@data LABEL=databackup /backup
sudo mkdir -p /backup/.snapshots
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
