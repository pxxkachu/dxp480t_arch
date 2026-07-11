# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, Qui, Sonarr, Radarr, Prowlarr, autobrr, Plex, Tailscale, and Caddy (HTTPS reverse proxy on `lehaus.io`).

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
127.0.1.1   dxp480tp.localdomain dxp480tp

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

<TS_IP>     <FQDN> dxp480tp
```

## 3. Create media group and pre-create arr service accounts

Create the shared media group:

```bash
sudo groupadd media
```

Create sonarr, radarr, prowlarr, plex, qui, autobrr, and caddy accounts **before** installing their packages. The AUR and pacman packages ship sysusers files that auto-create these accounts with their own default groups. Pre-creating them with the correct home directory prevents that — sysusers skips users that already exist.

```bash
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media sonarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media radarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media prowlarr
sudo useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media plex
sudo useradd --system --home-dir /var/lib/qui --shell /usr/bin/nologin --gid media qui
sudo useradd --system --home-dir /var/lib/autobrr --shell /usr/bin/nologin --gid media autobrr
sudo useradd --system --home-dir /var/lib/caddy --shell /usr/bin/nologin caddy
sudo passwd --lock sonarr
sudo passwd --lock radarr
sudo passwd --lock prowlarr
sudo passwd --lock plex
sudo passwd --lock qui
sudo passwd --lock autobrr
sudo passwd --lock caddy
```

## 4. Install qBittorrent

```bash
sudo pacman -S qbittorrent-nox
```

The package creates a user called `qbt` via sysusers. Fix its primary group and home directory:

```bash
sudo usermod --gid media qbt
sudo usermod -d /var/lib/qbt qbt
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

## 6. Install Sonarr, Radarr, Prowlarr, autobrr, Qui, and Plex (AUR)

**Run as your normal user — do NOT use sudo:**

```bash
paru -S --needed sonarr-bin radarr-bin prowlarr-bin autobrr qui plex-media-server
```

Fix group membership after install (AUR tmpfiles may reset permissions):

```bash
sudo usermod --gid media qui
sudo usermod --gid media autobrr
sudo usermod -aG media plex
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

sudo mkdir -p /var/lib/qui /var/lib/autobrr
sudo chown qui:media /var/lib/qui
sudo chown autobrr:media /var/lib/autobrr
sudo chmod 775 /var/lib/qui /var/lib/autobrr

sudo mkdir -p /var/lib/plex
sudo chown plex:plex /var/lib/plex
sudo chmod 755 /var/lib/plex

sudo mkdir -p /var/lib/caddy
sudo chown caddy:caddy /var/lib/caddy
sudo chmod 750 /var/lib/caddy
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
Environment=HOME=/var/lib/qbt
```

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

### Qui

[Qui](https://github.com/autobrr/qui) is a modern qBittorrent web UI from the autobrr team. It replaces the default Web UI, proxies qBittorrent for other apps (including autobrr), and includes built-in cross-seeding. Web UI on port **7476**.

Generate the config file before starting the service:

```bash
sudo -u qui /usr/bin/qui generate-config --config-dir /var/lib/qui
ls -la /var/lib/qui/config.toml
```

The AUR package ships a default unit. Override it to set the data directory, listen on all interfaces for Tailscale access (change to `127.0.0.1` in step 14 for HTTPS-only), and run as the `qui` user with group `media`:

```bash
sudo mkdir -p /etc/systemd/system/qui.service.d
sudo nano /etc/systemd/system/qui.service.d/override.conf

[Service]
Group=media
UMask=002
Environment=QUI__HOST=0.0.0.0
ExecStart=
ExecStart=/usr/bin/qui serve --config-dir /var/lib/qui --data-dir /var/lib/qui
```

### autobrr

autobrr monitors IRC announce channels and RSS feeds to automatically grab new releases and push them to qBittorrent. Web UI on port **7474**.

Pre-create the config so autobrr listens on all interfaces (needed for direct Tailscale access; change to `127.0.0.1` in step 14 for HTTPS-only). First generate a random session secret:

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

```bash
sudo chown autobrr:media /var/lib/autobrr/config.toml
sudo chmod 640 /var/lib/autobrr/config.toml
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

### Plex Media Server

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
sudo systemctl enable --now qbittorrent-nox@qbt sonarr radarr prowlarr qui autobrr plexmediaserver
```

Verify they're running:

```bash
systemctl status qbittorrent-nox@qbt sonarr radarr prowlarr qui autobrr plexmediaserver
```

Get qBittorrent's initial admin password from its journal:

```bash
sudo journalctl -u qbittorrent-nox@qbt -n 20 | grep -i password
```

## 12. Access services

All services are accessible from any device on your Tailscale network using the Tailscale IP. After step 14, use the HTTPS URLs on `lehaus.io` instead.

| Service      | URL                         |
|--------------|-----------------------------|
| Qui          | `http://<TS_IP>:7476`       |
| qBittorrent  | `http://<TS_IP>:8080`       |
| Sonarr       | `http://<TS_IP>:8989`       |
| Radarr       | `http://<TS_IP>:7878`       |
| Prowlarr     | `http://<TS_IP>:9696`       |
| Plex         | `http://<TS_IP>:32400/web`  |
| autobrr      | `http://<TS_IP>:7474`       |

## 13. Configure Qui and autobrr

### Qui

Visit `http://<TS_IP>:7476` and create your admin account.

1. **Add qBittorrent** — connect to the local instance at `http://127.0.0.1:8080` using the qBittorrent Web UI credentials from step 11.
2. **Sync indexers** — go to **Settings → Indexers** and use the Prowlarr 1-click sync (needed for cross-seeding).
3. **Cross-seed** — configure RSS automation or seeded search under the **Cross-Seed** page. See the [Qui cross-seeding docs](https://github.com/autobrr/qui/blob/main/README.md#cross-seed).
4. **Client proxy key for autobrr** — go to **Settings → Client Proxy Keys**, create a key for autobrr, and copy the full proxy URL (e.g. `http://localhost:7476/proxy/...`). You will need this below.

Check logs if anything goes wrong:

```bash
sudo journalctl -u qui -f
```

### autobrr

Visit `http://<TS_IP>:7474` to create your initial admin account.

Under **Settings → Download Clients**, add qBittorrent using the **Client Proxy URL** from Qui above — e.g. `http://localhost:7476/proxy/...`. Leave username and password blank; Qui handles qBittorrent authentication.

For real-time cross-seeding when autobrr announces releases, add Qui webhook filters under **External** in each autobrr filter. See the [Qui autobrr integration docs](https://github.com/autobrr/qui/blob/main/README.md#autobrr-integration).

Check logs if anything goes wrong:

```bash
sudo journalctl -u autobrr -f
```

## 14. Set up Caddy for HTTPS (`lehaus.io`)

Caddy acts as a tailnet-only reverse proxy with automatic HTTPS. Traffic between Tailscale devices is already encrypted via WireGuard; Caddy adds a TLS layer the browser trusts (no warnings, clipboard and other secure-context features work).

Services are reached at clean subdomains on port **443** — for example `https://sonarr.lehaus.io` — instead of `https://<FQDN>:10444`. Nothing is exposed to the public internet: DNS points at Tailscale IPs (`100.x.x.x`), which are only routable inside your tailnet.

Plex is proxied through Caddy for the **metadata web UI** on the tailnet only — see [Plex (metadata web UI only)](#plex-metadata-web-ui-only) below. Watching stays on Plex **remote access** and client discovery (unchanged).

### DNS primer: A records, wildcard, and Pi-hole

An **A record** maps a hostname to an **IPv4 address**. When your phone looks up `sonarr.lehaus.io`, Porkbun's DNS answers with an IP (your NAS Tailscale address); the browser connects to that IP over Tailscale.

A **wildcard A record** (`*` → `<TS_IP>`) makes most subdomains of `lehaus.io` resolve to the NAS — `qui.lehaus.io`, `qbit.lehaus.io`, `sonarr.lehaus.io`, and any future NAS service — with a single Porkbun entry. New NAS services only need a Caddy block; no DNS changes.

A **specific A record** beats a wildcard for that exact name. Pi-hole runs on the Raspberry Pi **`rpcmiv`** (CM4) with its own Tailscale IP — see [`rpcmiv/post_install.md`](../rpcmiv/post_install.md) for Caddy and Pi-hole HTTPS setup.

The bare apex (`lehaus.io` with no subdomain) is **not** covered by `*`; only `something.lehaus.io` is. That is fine — services use named subdomains.

The wildcard TLS certificate (`*.lehaus.io`) is issued separately via Porkbun's API (DNS-01 challenge) and is not the same thing as the wildcard `A` record. Both the NAS and the Pi can request certificates for names they serve under `*.lehaus.io`.

Off-tailnet, `100.x.x.x` addresses are unreachable even though they appear in public DNS. That is expected and keeps services private.

### Build Caddy with the Porkbun DNS module (NAS)

Stock Arch `caddy` does not include Porkbun support. Build a custom binary with `xcaddy` on the NAS — **run as your normal user, do NOT use sudo**:

```bash
paru -S --needed xcaddy
xcaddy build --with github.com/caddy-dns/porkbun --output /tmp/caddy
sudo install -m 755 /tmp/caddy /usr/local/bin/caddy
rm /tmp/caddy
```

If the build fails on a recent Caddy release, pin an older version:

```bash
xcaddy build v2.9.1 --with github.com/caddy-dns/porkbun --output /tmp/caddy
sudo install -m 755 /tmp/caddy /usr/local/bin/caddy
```

Confirm the module is present:

```bash
caddy list-modules | grep -i porkbun
```

### Enable Porkbun API access

1. Log in to the [Porkbun dashboard](https://porkbun.com/).
2. Open **Details** for `lehaus.io` → enable **API Access** for the domain.
3. Go to **Account** → **API Access** → create a key (e.g. `caddy-lehaus`).
4. Save the API key and secret key.

Store credentials on the NAS (not in the Caddyfile). Config and secrets live under `/var/lib/caddy`, same pattern as `/var/lib/qui` and `/var/lib/autobrr`:

```bash
sudo nano /var/lib/caddy/porkbun.env

PORKBUN_API_KEY=pk1_...
PORKBUN_SECRET_API_KEY=sk1_...
```

```bash
sudo chown caddy:caddy /var/lib/caddy/porkbun.env
sudo chmod 600 /var/lib/caddy/porkbun.env
```

Only Porkbun API keys go here — do not put `TAILNET_IP` in this file. The start script in the next section resolves it from `tailscale ip -4` at runtime.

Use the same Porkbun API key on **`rpcmiv`** — see [`rpcmiv/post_install.md`](../rpcmiv/post_install.md).

### Create DNS records in Porkbun

| Type | Host | Answer | TTL |
|------|------|--------|-----|
| A | `*` | `<TS_IP>` | 600 |
| A | `pihole` | `<PI_TS_IP>` | 600 |

The wildcard covers NAS services (`qui.lehaus.io`, `qbit.lehaus.io`, `sonarr.lehaus.io`, etc.). The `pihole` record overrides the wildcard for `pihole.lehaus.io` only (`<PI_TS_IP>` = `tailscale ip -4` on **rpcmiv**).

Verify from a tailnet device:

```bash
dig +short sonarr.lehaus.io
dig +short pihole.lehaus.io
```

Should return `<TS_IP>` and `<PI_TS_IP>` respectively.

### Configure Caddy on the NAS

`After=tailscaled.service` only waits for the Tailscale **daemon** — not for a `100.x` address on `tailscale0`. Use the same start script as **rpcmiv** to wait for Tailscale and export the live IP for `bind`.

```bash
sudo nano /usr/local/bin/caddy-tailscale.sh
```

```bash
#!/bin/bash
set -euo pipefail
set -a
source /var/lib/caddy/porkbun.env
set +a
for _ in $(seq 1 30); do
  TAILNET_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -n "${TAILNET_IP}" ]] && ip -4 addr show dev tailscale0 2>/dev/null | grep -q "inet ${TAILNET_IP}/"; then
    export TAILNET_IP
    exec /usr/local/bin/caddy run --environ --config /var/lib/caddy/Caddyfile
  fi
  sleep 1
done
echo "tailscale0 has no usable IPv4 after 30s" >&2
exit 1
```

```bash
sudo chmod 755 /usr/local/bin/caddy-tailscale.sh
```

Create the systemd unit (the custom xcaddy build does not install one — do not use a drop-in unless you also installed the `caddy` package from pacman):

```bash
sudo nano /etc/systemd/system/caddy.service

[Unit]
Description=Caddy
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy-tailscale.sh
ExecReload=/usr/local/bin/caddy reload --config /var/lib/caddy/Caddyfile
TimeoutStartSec=60
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/caddy
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Edit the Caddyfile:

```bash
sudo nano /var/lib/caddy/Caddyfile
```

```caddyfile
{
    email you@lehaus.io
    acme_dns porkbun {
        api_key {env.PORKBUN_API_KEY}
        api_secret_key {env.PORKBUN_SECRET_API_KEY}
    }
}

(tailnet) {
    bind {env.TAILNET_IP}
    @blocked not remote_ip 100.64.0.0/10
    respond @blocked "Unauthorized" 403
    tls {
        resolvers 1.1.1.1
    }
}

qbit.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:8080
}

qui.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:7476
}

sonarr.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:8989
}

radarr.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:7878
}

prowlarr.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:9696
}

autobrr.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:7474
}

plex.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:32400 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

Replace `you@lehaus.io` with your email (used for Let's Encrypt account notices).

```bash
sudo chown caddy:caddy /var/lib/caddy/Caddyfile
```

### Start Caddy on the NAS

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now caddy
systemctl status caddy
```

Caddy requests a Let's Encrypt certificate via Porkbun DNS-01 on the first HTTPS request. Certificates renew automatically.

Check logs if anything goes wrong:

```bash
sudo journalctl -u caddy -f
```

Common issues: Porkbun API access not enabled for `lehaus.io`, typo in API keys, or Tailscale not connected.

**`bind: cannot assign requested address`** — stale hardcoded IP or Tailscale not ready. Confirm the wrapper script is in use (`systemctl cat caddy | grep caddy-tailscale`), then:

```bash
tailscale ip -4
ip -4 addr show dev tailscale0
sudo journalctl -u caddy -n 20
```

Remove `TAILNET_IP` from `porkbun.env` if present — the wrapper sets it at start. If Tailscale is down, run `sudo tailscale up`, then `sudo systemctl restart caddy`.

### HTTPS access (NAS)

| Service     | HTTPS URL                         |
|-------------|-----------------------------------|
| Qui         | `https://qui.lehaus.io`           |
| qBittorrent | `https://qbit.lehaus.io`          |
| Sonarr      | `https://sonarr.lehaus.io`        |
| Radarr      | `https://radarr.lehaus.io`        |
| Prowlarr    | `https://prowlarr.lehaus.io`      |
| autobrr     | `https://autobrr.lehaus.io`       |
| Plex (web)  | `https://plex.lehaus.io/web`      |

Pi-hole (`https://pihole.lehaus.io`) is on **rpcmiv** — see [`rpcmiv/post_install.md`](../rpcmiv/post_install.md).

### Plex (metadata web UI only)

Caddy gives you a consistent `lehaus.io` URL for editing library metadata in the browser. It is **not** a replacement for Plex remote access — leave **Settings → Remote Access** enabled and keep using Plex apps for watching (discovery and relay work as before).

`plex.lehaus.io` is covered by the wildcard `A` record; no Porkbun changes needed.

In Plex → **Settings → Network** (admin account):

1. **Custom server access URLs** — add:
   ```
   https://plex.lehaus.io
   ```
   This stops the web app from redirecting to `:32400` or the wrong host when you open the Caddy URL.
2. Leave **Remote access** enabled.

Open `https://plex.lehaus.io/web` from any tailnet device. Sign out and back in once if the web client still shows the old URL.

If the web UI misbehaves (redirect loops, blank page), Plex may be serving HTTPS on port 32400 locally. Change the Caddy block to proxy `https://127.0.0.1:32400` with `tls_insecure_skip_verify` on the upstream transport instead of plain `http://127.0.0.1:32400`.

**Do not** bind Plex to `127.0.0.1` in the [HTTPS-only lockdown](#enforce-https-only-recommended) below — remote access and client discovery need Plex listening on its normal interface.

### Enforce HTTPS-only (recommended)

After confirming HTTPS works, bind each service to `127.0.0.1` so it is only reachable through Caddy:

**qBittorrent** — in `/var/lib/qbt/.config/qBittorrent/qBittorrent.conf`:

```ini
[Preferences]
WebUI\Address=127.0.0.1
```

**Qui** — in `/etc/systemd/system/qui.service.d/override.conf`, change the bind address:

```ini
Environment=QUI__HOST=127.0.0.1
```

**autobrr** — in `/var/lib/autobrr/config.toml`:

```toml
host = "127.0.0.1"
```

**Sonarr / Radarr / Prowlarr** — in each app's `config.xml`, set `<BindAddress>127.0.0.1</BindAddress>` (under Settings → General in the web UI, or edit the file directly while the service is stopped).

**Plex** — skip this step. Remote access and app discovery require Plex to keep its default listen address; use `https://plex.lehaus.io/web` on the tailnet for metadata instead of locking down `:32400`.

Restart affected services:

```bash
sudo systemctl restart qbittorrent-nox@qbt qui sonarr radarr prowlarr autobrr
```

Confirm direct tailnet access no longer works (should time out or refuse):

```bash
curl -m 3 http://<TS_IP>:8989 || echo "blocked as expected"
```

HTTPS via Caddy should still work from any tailnet device.

## 15. Set up Btrfs data SSD

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
# Strict mode: Exit on error, undefined vars, or pipe failures
set -euo pipefail

# CONFIGURATION
SOURCE_SUBVOL="/data"
SNAP_DIR="/data/.snapshots"
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

## 16. (Future) Add backup SSD with btrfs send/receive

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
