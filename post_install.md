# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, VueTorrent, Qui, Sonarr, Radarr, Prowlarr, Unpackerr, Plex, and Tailscale (remote access over your tailnet).

All commands include `sudo` where needed — copy and paste directly into your terminal as your normal user. Steps 1 and 5 **must not** use sudo (AUR packages must be built as a normal user).

---

## 1. Install paru (AUR helper)

Builds a tagged release once with `makepkg`, linked against your installed `pacman` / `libalpm`. `install.sh` already installs `base-devel`, `go`, and `git`; the first build also pulls `cargo` (Rust) as a make dependency.

Avoid **`paru-bin`** on a rolling system: its prebuilt binary is tied to a specific `libalpm.so` soname and can break after a `pacman` upgrade (`libalpm.so.15: cannot open shared object file`). Use **`paru`** or **`paru-git`** instead — both compile against whatever `libalpm` you have.

**Run as your normal user — do NOT use sudo:**

```bash
git clone https://aur.archlinux.org/paru.git /tmp/paru
cd /tmp/paru
makepkg -si --noconfirm
cd -
rm -rf /tmp/paru
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

Create sonarr, radarr, prowlarr, plex, autobrr, and qui accounts **before** installing their AUR packages. The AUR packages ship sysusers files that auto-create these accounts with their own default groups. Pre-creating them with primary group `media` prevents that — sysusers skips users that already exist.

```bash
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media sonarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media radarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media prowlarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media plex
sudo useradd --system --no-create-home --home-dir /var/lib/autobrr --shell /usr/bin/nologin --gid media autobrr
sudo useradd --system --no-create-home --home-dir /var/lib/qui --shell /usr/bin/nologin --gid media qui
sudo passwd --lock sonarr
sudo passwd --lock radarr
sudo passwd --lock prowlarr
sudo passwd --lock plex
sudo passwd --lock autobrr
sudo passwd --lock qui
```

## 5. Install Sonarr, Radarr, Prowlarr (AUR)

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed sonarr-bin radarr-bin prowlarr-bin
```

## 6. Add admin user to media group

```bash
sudo usermod -aG media admin
```

Log out and back in after this step for the group membership to take effect.

## 7. Install qBittorrent, VueTorrent, and create service data directories

### Install qBittorrent

```bash
sudo pacman -S qbittorrent-nox
```

The package creates user `qbt` and home **`/var/lib/qbittorrent`** via sysusers/tmpfiles. Fix its primary group and directory permissions for the `media` group:

```bash
sudo usermod --gid media qbt
sudo passwd --lock qbt
sudo chown qbt:media /var/lib/qbittorrent
sudo chmod 775 /var/lib/qbittorrent
```

### Create service data directories

```bash
sudo mkdir -p /var/lib/sonarr
sudo chown sonarr:media /var/lib/sonarr
sudo chmod 775 /var/lib/sonarr

sudo mkdir -p /var/lib/radarr
sudo chown radarr:media /var/lib/radarr
sudo chmod 775 /var/lib/radarr

sudo mkdir -p /var/lib/prowlarr
sudo chown prowlarr:media /var/lib/prowlarr
sudo chmod 775 /var/lib/prowlarr

sudo mkdir -p /var/lib/autobrr
sudo chown autobrr:media /var/lib/autobrr
sudo chmod 775 /var/lib/autobrr

sudo mkdir -p /var/lib/qui
sudo chown qui:media /var/lib/qui
sudo chmod 775 /var/lib/qui
```

### Install and configure VueTorrent

[VueTorrent](https://github.com/VueTorrent/VueTorrent) replaces qBittorrent’s default Web UI. It is **not** a separate service — qbittorrent-nox serves it as the alternative Web UI from the same port (8080).

Download the latest release into the `qbt` user’s home. The target directory must contain a `public/` subfolder ([upstream requirement](https://github.com/VueTorrent/VueTorrent/wiki/Installation)):

```bash
sudo mkdir -p /var/lib/qbittorrent/VueTorrent
cd /tmp
curl -sL https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip -o vuetorrent.zip
unzip -o vuetorrent.zip
sudo cp -a VueTorrent/. /var/lib/qbittorrent/VueTorrent/
rm -rf VueTorrent vuetorrent.zip
sudo chown -R qbt:media /var/lib/qbittorrent/VueTorrent
```

Verify:

```bash
ls /var/lib/qbittorrent/VueTorrent/public
```

If `public/` is missing, the zip layout may differ — unzip manually and copy the folder that contains `public/` and `version.txt` into `/var/lib/qbittorrent/VueTorrent/`.

**Alternative (AUR):** `paru -S vuetorrent-bin` (paru installed in section 1). Prefer the manual install above: qBittorrent rejects symlinked alternative UI paths, and a plain directory copy is more reliable.

Set this in qBittorrent’s config **before** the first service start (or edit after qBittorrent has run once):

```bash
sudo mkdir -p /var/lib/qbittorrent/.config/qBittorrent
sudo nano /var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf
```

```ini
[Preferences]
WebUI\AlternativeUIEnabled=true
WebUI\RootFolder=/var/lib/qbittorrent/VueTorrent
```

`RootFolder` must be the directory **containing** `public/` — not the `public` folder itself.

Equivalent Web UI path: Options → Web UI → enable **Use alternative Web UI**, set **Files location** to `/var/lib/qbittorrent/VueTorrent`.

If qBittorrent is already running, restart after changes:

```bash
sudo systemctl restart qbittorrent-nox@qbt
```

If you see *“Unacceptable file type, only regular file is allowed”*, the path is wrong (usually pointing at `public/` instead of its parent) or contains symlinks.

## 8. Create media directories

```bash
sudo mkdir -p /media/downloads/{pending,complete,torrents}
sudo mkdir -p /media/{movies,shows}

sudo chown qbt:media /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents
sudo chown radarr:media /media/movies
sudo chown sonarr:media /media/shows

sudo chmod 2775 /media/downloads /media/downloads/pending /media/downloads/complete /media/downloads/torrents /media/movies /media/shows
```

The setgid bit (2775) ensures new files inherit the `media` group regardless of which service creates them.

## 9. Configure systemd services

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

## 10. Install and configure Plex Media Server

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

## 11. Start all services

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

## 12. Remote access

Services are reachable from any device on your Tailscale tailnet. Traffic is encrypted by WireGuard; web UIs use HTTP on their default ports.

| Service     | URL |
|-------------|-----|
| qBittorrent / VueTorrent | `http://kintoun.peacock-pomfret.ts.net:8080` |
| autobrr     | `http://kintoun.peacock-pomfret.ts.net:7474` (section 13) |
| Qui         | `http://kintoun.peacock-pomfret.ts.net:7476` (section 14) |
| Sonarr      | `http://kintoun.peacock-pomfret.ts.net:8989` |
| Radarr      | `http://kintoun.peacock-pomfret.ts.net:7878` |
| Prowlarr    | `http://kintoun.peacock-pomfret.ts.net:9696` |
| Plex        | `http://kintoun.peacock-pomfret.ts.net:32400/web` |

Fallback if MagicDNS is unavailable — replace `<TS_IP>` with the output of `tailscale ip -4`:

| Service     | URL |
|-------------|-----|
| qBittorrent / VueTorrent | `http://<TS_IP>:8080` |
| autobrr     | `http://<TS_IP>:7474` |
| Qui         | `http://<TS_IP>:7476` |
| Sonarr      | `http://<TS_IP>:8989` |
| Radarr      | `http://<TS_IP>:7878` |
| Prowlarr    | `http://<TS_IP>:9696` |
| Plex        | `http://<TS_IP>:32400/web` |

### Plex network settings

For Plex mobile and TV apps over Tailscale, open the Plex web UI → **Settings** → **Network** and set:

| Setting | Value |
|---------|--------|
| Secure connections | **Preferred** (not Required — avoids cert errors with Tailscale IPs) |
| Custom server access URLs | `http://kintoun.peacock-pomfret.ts.net:32400` |
| Enable Remote Access | **On** if Plex friends are not on your tailnet; **Off** if all viewers use Tailscale only |

## 13. Install and configure autobrr

[autobrr](https://autobrr.com) monitors IRC announce channels and RSS feeds, matches releases against your filters, and sends grabs to qBittorrent and your *arr* apps. It sits between Prowlarr (indexers) and qBittorrent (downloads) in this stack. [Qui](https://getqui.com) (section 14) handles cross-seeding separately.

The AUR package **`autobrr`** ships a systemd unit, sysusers, and tmpfiles. Config, SQLite database, and logs live under **`/var/lib/autobrr`**. The `autobrr` system user and that directory were pre-created in sections 4 and 7 with primary group `media`.

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed autobrr
```

Confirm ownership after install (the package tmpfiles may reset permissions):

```bash
sudo usermod --gid media autobrr
sudo chown autobrr:media /var/lib/autobrr
sudo chmod 775 /var/lib/autobrr
```

### Generate config file

The vendor unit passes `--config=/var/lib/autobrr`. Bootstrap `config.toml` and the SQLite database **before** enabling systemd — a cold start under the hardened unit can fail if the directory is empty:

```bash
sudo -u autobrr timeout --signal=TERM 15s /usr/bin/autobrr --config=/var/lib/autobrr || true
```

Verify:

```bash
ls -la /var/lib/autobrr/config.toml /var/lib/autobrr/autobrr.db
```

`timeout` stopping the process with SIGTERM is expected. `AUTOBRR__HOST=0.0.0.0` in the drop-in below overrides the default `host = "127.0.0.1"` in `config.toml` for Tailscale access.

### systemd drop-in override

Run with group `media`, listen on all interfaces for Tailscale, and start after qBittorrent and the *arr* apps:

```bash
sudo mkdir -p /etc/systemd/system/autobrr.service.d
sudo nano /etc/systemd/system/autobrr.service.d/override.conf

[Unit]
After=network-online.target qbittorrent-nox@qbt.service prowlarr.service sonarr.service radarr.service

[Service]
Group=media
UMask=002
Environment=AUTOBRR__HOST=0.0.0.0
```

The vendor unit already runs as user `autobrr` with `--config=/var/lib/autobrr`. `Group=media` and `UMask=002` match the other download-stack services.

### Start autobrr

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now autobrr
systemctl status autobrr
```

### First-time web setup

Open `http://kintoun.peacock-pomfret.ts.net:7474` (or `http://<TS_IP>:7474`) and create the autobrr admin account.

Then in the autobrr UI:

1. **Settings → Download clients** — add qBittorrent:
   - Host: `http://127.0.0.1:8080`
   - Username / password: qBittorrent Web UI credentials (from `journalctl` in section 11 if you have not changed them yet)
2. **Settings → Feeds** — optional Torznab feeds from Prowlarr (copy URL + API key from Prowlarr → Indexers)
3. **Settings → IRC** — connect to indexer announce channels ([autobrr IRC docs](https://autobrr.com/configuration/irc))
4. **Filters** — create release filters that send matches to qBittorrent and notify Sonarr/Radarr

Follow logs:

```bash
sudo journalctl -u autobrr -f
```

Reference: [autobrr configuration](https://autobrr.com/configuration/autobrr).

## 14. Install and configure Qui

[Qui](https://github.com/autobrr/qui) is a qBittorrent web UI from the [autobrr](https://autobrr.com) team. It replaces the standalone [cross-seed](https://cross-seed.org) daemon with a built-in cross-seed module (RSS automation, library scans, auto-search on completion, hardlinking) and runs as its own service on port **7476**. VueTorrent on port **8080** (section 7) can stay for direct qBittorrent Web UI access, or you can use Qui as your primary interface.

The AUR package **`qui-bin`** ships a prebuilt Go binary (no Node.js), plus systemd, sysusers, and tmpfiles units. The `qui` system user and `/var/lib/qui` were pre-created in sections 4 and 7 with primary group `media`.

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed qui-bin
```

Confirm ownership after install (the package tmpfiles may reset permissions):

```bash
sudo usermod --gid media qui
sudo chown qui:media /var/lib/qui
sudo chmod 775 /var/lib/qui
```

### Generate config file

The override below points `--config-dir` at `/var/lib/qui`. Create `config.toml` there **before** starting the service — `qui serve` expects that file (or a writable directory to create it), and systemd will fail on first boot if neither is in place:

```bash
sudo -u qui /usr/bin/qui generate-config --config-dir /var/lib/qui
```

Verify:

```bash
ls -la /var/lib/qui/config.toml
```

This command skips if `config.toml` already exists. `QUI__HOST=0.0.0.0` in the drop-in below still overrides the `host` value in the file for Tailscale access.

### systemd drop-in override

Store config and data directly under `/var/lib/qui` (same layout as Sonarr/Radarr), run with group `media`, listen on all interfaces for Tailscale, and start after qBittorrent:

```bash
sudo mkdir -p /etc/systemd/system/qui.service.d
sudo nano /etc/systemd/system/qui.service.d/override.conf

[Unit]
After=network-online.target qbittorrent-nox@qbt.service

[Service]
Group=media
UMask=002
Environment=QUI__HOST=0.0.0.0
ExecStart=
ExecStart=/usr/bin/qui serve --config-dir /var/lib/qui --data-dir /var/lib/qui
```

`ExecStart=` clears the vendor line before setting a new one. `--config-dir` and `--data-dir` place `config.toml` and `qui.db` in `/var/lib/qui` instead of `~/.config/qui`.

### Start Qui

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qui
systemctl status qui
```

### First-time web setup

Open `http://kintoun.peacock-pomfret.ts.net:7476` (or `http://<TS_IP>:7476`) and create the Qui admin account.

Then in the Qui UI:

1. **Settings → qBittorrent instances** — add your instance:
   - Host: `http://127.0.0.1:8080`
   - Username / password: qBittorrent Web UI credentials (from `journalctl` in section 11 if you have not changed them yet)
2. **Cross-Seed** — enable and configure per the [Qui cross-seed docs](https://getqui.com/docs/features/cross-seed/overview):
   - Connect **Prowlarr** Torznab feeds (copy API URLs from Prowlarr → Indexers)
   - Set **link directories** to `/media/downloads/complete` for hardlinking (requires `qui`/`media` group access to download paths — already set via setgid dirs in section 8)
   - Enable **Auto-search on completion** and/or RSS automation as desired
3. Optional: connect **Sonarr** / **Radarr** in Qui settings for season-pack assembly and tighter *arr* integration

Follow logs:

```bash
sudo journalctl -u qui -f
```

Reference: [Qui documentation](https://getqui.com).

## 15. Install and configure Unpackerr

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

## 16. Set up Btrfs data SSD

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

## 17. (Future) Add backup SSD with btrfs send/receive

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
