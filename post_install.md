# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, VueTorrent, Sonarr, Radarr, Prowlarr, Unpackerr, Plex, and Tailscale Serve (HTTPS remote access over your tailnet).

All commands include `sudo` where needed — copy and paste directly into your terminal as your normal user. Steps 1 and 7 **must not** use sudo (AUR packages must be built as a normal user).

---

## 1. Install paru (AUR helper)

**Run as your normal user — do NOT use sudo:**

```bash
git clone https://aur.archlinux.org/paru-git.git /tmp/paru-git
cd /tmp/paru-git
makepkg -si --noconfirm
cd -
rm -rf /tmp/paru-git
```

## 2. Install and authenticate Tailscale

```bash
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Follow the printed authentication link in a browser.

This machine's Tailscale FQDN is **`kintoun.peacock-pomfret.ts.net`**. After authenticating, confirm the assigned IP:

```bash
tailscale ip -4
```

Note that value as `<TS_IP>` below (the IP can change; the FQDN is stable).

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

## 3. Update /etc/hosts

```bash
sudo nano /etc/hosts

127.0.0.1   localhost
127.0.1.1   kintoun.localdomain kintoun

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

<TS_IP>     kintoun.peacock-pomfret.ts.net kintoun
```

## 4. Create media group and pre-create arr service accounts

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

## 5. Install qBittorrent

```bash
sudo pacman -S qbittorrent-nox
```

The package creates a user called `qbt` via sysusers with home **`/var/lib/qbittorrent`**. Fix its primary group to `media`:

```bash
sudo usermod --gid media qbt
sudo passwd --lock qbt
```

## 6. Install and configure VueTorrent

[VueTorrent](https://github.com/VueTorrent/VueTorrent) replaces qBittorrent’s default Web UI. It is **not** a separate service — qbittorrent-nox serves it as the alternative Web UI from the same port (8080 / Tailscale Serve 9001).

### Download VueTorrent

Download the latest release into the `qbt` user’s home. The target directory must contain a `public/` subfolder ([upstream requirement](https://github.com/VueTorrent/VueTorrent/wiki/Installation)):

```bash
sudo mkdir -p /var/lib/qbittorrent/vuetorrent
cd /tmp
curl -sL https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip -o vuetorrent.zip
unzip -o vuetorrent.zip
sudo cp -a vuetorrent/. /var/lib/qbittorrent/vuetorrent/
rm -rf vuetorrent vuetorrent.zip
sudo chown -R qbt:media /var/lib/qbittorrent/vuetorrent
```

Verify:

```bash
ls /var/lib/qbittorrent/vuetorrent/public
```

If `public/` is missing, the zip layout may differ — unzip manually and copy the folder that contains `public/` and `version.txt` into `/var/lib/qbittorrent/vuetorrent/`.

**Alternative (AUR):** `paru -S vuetorrent-bin` (paru installed in section 1). Prefer the manual install above: qBittorrent rejects symlinked alternative UI paths, and a plain directory copy is more reliable.

### Enable alternative Web UI

Set this in qBittorrent’s config **before** the first service start (or edit after qBittorrent has run once):

```bash
sudo mkdir -p /var/lib/qbittorrent/.config/qBittorrent
sudo nano /var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf
```

```ini
[Preferences]
WebUI\AlternativeUIEnabled=true
WebUI\RootFolder=/var/lib/qbittorrent/vuetorrent
```

`RootFolder` must be the directory **containing** `public/` — not the `public` folder itself.

Equivalent Web UI path: Options → Web UI → enable **Use alternative Web UI**, set **Files location** to `/var/lib/qbittorrent/vuetorrent`.

If qBittorrent is already running, restart after changes:

```bash
sudo systemctl restart qbittorrent-nox@qbt
```

If you see *“Unacceptable file type, only regular file is allowed”*, the path is wrong (usually pointing at `public/` instead of its parent) or contains symlinks.

## 7. Install Sonarr, Radarr, Prowlarr (AUR)

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed sonarr-bin radarr-bin prowlarr-bin
```

## 8. Add admin user to media group

```bash
sudo usermod -aG media admin
```

Log out and back in after this step for the group membership to take effect.

## 9. Create service data directories

```bash
sudo mkdir -p /var/lib/qbittorrent
sudo chown qbt:media /var/lib/qbittorrent
sudo chmod 775 /var/lib/qbittorrent

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

## 10. Create media directories

```bash
sudo mkdir -p /media/downloads/{pending,complete,torrents}
sudo mkdir -p /media/{movies,shows}

sudo chown qbt:media /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
sudo chown radarr:media /media/movies
sudo chown sonarr:media /media/shows

sudo chmod 2775 /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents /media/movies /media/shows
```

The setgid bit (2775) ensures new files inherit the `media` group regardless of which service creates them.

## 11. Configure systemd services

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

## 12. Install and configure Plex Media Server

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

## 13. Start all services

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

## 14. Remote access

Services are reachable from any device on your Tailscale tailnet. Use **HTTPS via Tailscale Serve** (section 15) for day-to-day remote access. Direct HTTP on `<TS_IP>` remains available until you bind apps to `127.0.0.1` in section 15.

### HTTPS via Tailscale Serve (recommended — after section 15)

| Service     | URL |
|-------------|-----|
| qBittorrent | `https://kintoun.peacock-pomfret.ts.net:9001` |
| Sonarr      | `https://kintoun.peacock-pomfret.ts.net:9002` |
| Radarr      | `https://kintoun.peacock-pomfret.ts.net:9003` |
| Prowlarr    | `https://kintoun.peacock-pomfret.ts.net:9004` |

Plex and cross-seed are not proxied through Serve (see below).

### Plex (direct)

| Access | URL |
|--------|-----|
| Web UI | `http://kintoun.peacock-pomfret.ts.net:32400/web` |
| Fallback | `http://<TS_IP>:32400/web` |

Plex uses its own `*.plex.direct` TLS for apps; configure Network settings in section 15.

### HTTP (direct — fallback before section 15)

| Service     | URL |
|-------------|-----|
| qBittorrent | `http://<TS_IP>:8080` |
| Sonarr      | `http://<TS_IP>:8989` |
| Radarr      | `http://<TS_IP>:7878` |
| Prowlarr    | `http://<TS_IP>:9696` |

cross-seed has no web UI.

## 15. Configure Tailscale Serve

[Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve) reverse-proxies each web UI over HTTPS with automatically provisioned certificates on `kintoun.peacock-pomfret.ts.net`. Traffic stays on your tailnet — no router port forwarding and no extra reverse-proxy package.

Use **one HTTPS port per service** (not path-based routing). Ports **9001–9004** map to qBittorrent → Sonarr → Radarr → Prowlarr in order. The *arr* apps and qBittorrent are single-page apps; path routing breaks asset loading.

Plex and cross-seed are excluded: Plex uses its own certificates; cross-seed has no web UI.

### Enable HTTPS certificates

In the [Tailscale admin console](https://login.tailscale.com/admin/dns), enable **HTTPS Certificates** under DNS settings.

### Bind web UIs to localhost

Restrict each app to `127.0.0.1` so it is only reachable through Tailscale Serve (or local inter-service calls on the NAS). Configure each app **before** running the `tailscale serve` commands below.

| App | Where to set bind address |
|-----|---------------------------|
| qBittorrent | Web UI → Options → Web UI → **IP address**: `127.0.0.1` |
| Sonarr | Settings → General → **Bind Address**: `127.0.0.1` |
| Radarr | Settings → General → **Bind Address**: `127.0.0.1` |
| Prowlarr | Settings → General → **Bind Address**: `127.0.0.1` |

Restart affected services after changing bind addresses:

```bash
sudo systemctl restart qbittorrent-nox@qbt sonarr radarr prowlarr
```

### qBittorrent behind Serve (required)

qBittorrent enforces **Host header**, **CSRF**, and **cookie** checks that Sonarr/Radarr/Prowlarr do not. Tailscale Serve terminates HTTPS on port **9001** and forwards to **8080** — the browser sends `Host: kintoun.peacock-pomfret.ts.net:9001` while qBittorrent listens on **8080**. Unlike nginx, Serve cannot rewrite Host headers or mark session cookies `Secure`, so the default qBittorrent security settings often return `Unauthorized` (VueTorrent uses the same API).

Stop qBittorrent before editing — a running instance will overwrite the config on exit:

```bash
sudo systemctl stop qbittorrent-nox@qbt
getent passwd qbt    # confirm home directory
sudo nano /var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf
```

If that file does not exist yet, start qBittorrent once to generate it, then stop and edit:

```bash
sudo systemctl start qbittorrent-nox@qbt
sleep 3
sudo systemctl stop qbittorrent-nox@qbt
sudo find /var -name qBittorrent.conf 2>/dev/null
```

Use this **known-working block** for Tailscale Serve on a private tailnet (merge into `[Preferences]`; remove conflicting `WebUI\…` lines if present):

```ini
[Preferences]
WebUI\Address=127.0.0.1
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\SecureCookie=false
WebUI\LocalHostAuth=false
```

| Setting | Why |
|---------|-----|
| `HostHeaderValidation=false` | Serve uses port **9001** in the Host header; qBittorrent listens on **8080** — validation fails without this ([upstream issue](https://github.com/qbittorrent/qBittorrent/issues/23537)) |
| `CSRFProtection=false` | Serve does not strip/normalize `Referer`/`Origin` like nginx; CSRF checks fail on API calls after the page loads |
| `SecureCookie=false` | Serve terminates TLS; qBittorrent serves plain HTTP on localhost — session cookies do not stick without nginx’s `proxy_cookie_path … Secure` hack |
| `LocalHostAuth=false` | Serve forwards to qBittorrent as `127.0.0.1`; `LocalHostAuth=true` can cause confusing auth behaviour through the proxy |

Equivalent Web UI (Options → Web UI): **IP address** `127.0.0.1`, disable **Host header validation**, **CSRF protection**, and **Secure cookie**; ensure **Bypass authentication for clients on localhost** is off.

**VueTorrent:** configured in section 6 — same origin as qBittorrent; no separate backend URL.

Start qBittorrent, clear browser cookies for `kintoun.peacock-pomfret.ts.net`, then test in a private window:

```bash
sudo systemctl start qbittorrent-nox@qbt
```

Sanity check from another tailnet machine:

```bash
curl -sk https://kintoun.peacock-pomfret.ts.net:9001/api/v2/app/version
```

You should get a version string, not `Unauthorized`. If login is still required, open `https://kintoun.peacock-pomfret.ts.net:9001/` and sign in with the qBittorrent Web UI credentials (not VueTorrent-specific credentials).

**Still broken?** Confirm Serve is proxying the right backend:

```bash
tailscale serve status
curl -s http://127.0.0.1:8080/api/v2/app/version   # must work locally first
```

**Fallback:** skip Serve for qBittorrent and use `http://<TS_IP>:8080` over Tailscale (still encrypted by WireGuard). Keep Serve for the *arr* apps on 9002–9004.

### Expose services with Serve

Run each command once. The `--bg` flag keeps Serve running in the background and it resumes automatically after reboot.

```bash
sudo tailscale serve --bg --https=9001 http://127.0.0.1:8080 # qBittorrent
sudo tailscale serve --bg --https=9002 http://127.0.0.1:8989 # Sonarr
sudo tailscale serve --bg --https=9003 http://127.0.0.1:7878 # Radarr
sudo tailscale serve --bg --https=9004 http://127.0.0.1:9696 # Prowlarr
```

Verify the configuration:

```bash
tailscale serve status
```

Tailscale Serve fetches a certificate on the first HTTPS request to each port. Certificates renew automatically.

To remove all Serve routes:

```bash
sudo tailscale serve reset
```

### Plex network settings

Plex is not proxied through Serve. For Plex mobile and TV apps over Tailscale, open the Plex web UI → **Settings** → **Network** and set:

| Setting | Value |
|---------|--------|
| Secure connections | **Preferred** (not Required — avoids cert errors with Tailscale IPs) |
| Custom server access URLs | `http://kintoun.peacock-pomfret.ts.net:32400` |
| Enable Remote Access | **Off** (Tailscale replaces public port forwarding) |

## 16. Install and configure cross-seed

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

## 17. Install and configure Unpackerr

[Unpackerr](https://unpackerr.zip/) watches qBittorrent-completed downloads that Sonarr/Radarr are waiting on and **extracts archives** (RAR, zip, etc.) in place so the *arr* apps can import the unpacked files. It has **no web UI** (optional Prometheus metrics on `5656` if enabled in config). It uses each app’s download queue over HTTP API—use the Sonarr and Radarr API keys from Settings → General → Security in each app.

**Run as your normal user — do NOT use sudo:**

```bash
paru -S unpackerr
```

The AUR package creates the `unpackerr` user, installs `/usr/bin/unpackerr`, and ships `/etc/unpackerr/unpackerr.conf` (backup file on upgrades). Add the user to the `media` group and create the log directory expected by the vendor systemd unit (`UN_LOG_FILE=/var/log/unpackerr/unpackerr.log`):

```bash
sudo usermod -aG media unpackerr
sudo mkdir -p /var/log/unpackerr
sudo chown unpackerr:media /var/log/unpackerr
sudo chmod 775 /var/log/unpackerr
```

Add a drop-in override so the service runs with group `media` and `umask` 002 (same pattern as Sonarr/Radarr), and starts after qBittorrent and the *arr* apps:

```bash
sudo mkdir -p /etc/systemd/system/unpackerr.service.d
sudo nano /etc/systemd/system/unpackerr.service.d/override.conf

[Unit]
Description=Unpackerr
After=network-online.target qbittorrent-nox@qbt.service sonarr.service radarr.service

[Service]
Group=media
UMask=002
```

Edit the main config and uncomment **`url`**, **`api_key`**, and **`paths`** inside each `[[sonarr]]` and `[[radarr]]` block you use (comment out or remove unused Starr blocks to avoid startup warnings):

```bash
sudo nano /etc/unpackerr/unpackerr.conf
```

| Setting | Value |
|---------|--------|
| `[[sonarr]]` → `url` | `http://127.0.0.1:8989` |
| `[[sonarr]]` → `api_key` | Sonarr → Settings → General → Security |
| `[[sonarr]]` → `paths` | `['/media/downloads/complete']` (fallback if the path from the API is not visible to unpackerr) |
| `[[radarr]]` → `url` | `http://127.0.0.1:7878` |
| `[[radarr]]` → `api_key` | Radarr → Settings → General → Security |
| `[[radarr]]` → `paths` | `['/media/downloads/complete']` |

Keep `protocols` at the default for torrent-only; if you use Usenet, add `usenet,UsenetDownloadProtocol` as described in the file comments. For torrents, do **not** enable `delete_orig` unless you understand the implications (see upstream docs).

Start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now unpackerr
systemctl status unpackerr
```

Follow logs:

```bash
sudo journalctl -u unpackerr -f
```

Reference: [Unpackerr configuration](https://unpackerr.zip/docs/install/configuration/).

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

For the **`/media`** Btrfs pool (see pre-flight checks), keep daily read-only snapshots under `/media/.snapshots` on the **same filesystem** as `/media`. Create the directory if needed:

```bash
sudo mkdir -p /media/.snapshots
```

```bash
sudo nano /usr/local/bin/daily-data-snapshot.sh

#!/usr/bin/env bash
# Strict mode: Exit on error, undefined vars, or pipe failures
set -euo pipefail

# CONFIGURATION — /media RAID pool only (not /data)
SOURCE_SUBVOL="/media"
SNAP_DIR="/media/.snapshots"
# Naming with date for easy sorting and send/receive identification
TIMESTAMP=$(date +%Y-%m-%d)
KEEP=14

# 1. Create a new read-only snapshot
# Snapshots must be read-only (-r) to be used with 'btrfs send'
if [ ! -d "${SNAP_DIR}/${TIMESTAMP}" ]; then
    btrfs subvolume snapshot -r "$SOURCE_SUBVOL" "${SNAP_DIR}/${TIMESTAMP}"
    echo "Created daily snapshot: ${TIMESTAMP}"
else
    echo "Snapshot for ${TIMESTAMP} already exists. Skipping."
fi

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
ls /media/.snapshots/
```

### Create systemd timer and service for daily snapshots

```bash
# Service
sudo nano /etc/systemd/system/daily-data-snapshot.service

[Unit]
Description=Daily /media snapshot
Requires=media.mount
After=media.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-data-snapshot.sh
# Runs the script with lower priority so it doesn't slow down the PC
Nice=19
IOSchedulingClass=idle

# Timer
sudo nano /etc/systemd/system/daily-data-snapshot.timer

[Unit]
Description=Create daily /media snapshots

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

If daily snapshots are stored under **`/media/.snapshots`** (see the snapshot script above) rather than **`/data/.snapshots`**, use `/media/.snapshots` in place of `/data/.snapshots` in the commands below.

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
