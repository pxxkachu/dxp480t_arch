# Arch NAS (UGREEN DXP480T Plus)

Arch Linux install (`install.sh`) and post-install configuration for the UGREEN DXP480T Plus NAS.

---

## Installation — run from the git repo (Arch live ISO)

Run these steps on the **official Arch Linux live ISO** (UEFI boot, networking required). The script **wipes every disk you select** (OS disk plus data-array disks).

### Before you start

1. **BIOS:** UEFI mode (CSM/Legacy off). Disable Secure Boot if the live USB will not boot. On UGREEN boxes when not running UGOS, disable the hardware watchdog.
2. **Network:** Ethernet preferred — verify with `ping -c 3 archlinux.org`.
3. **Live session:** Open a root shell (you are root on tty1 by default).

### Clone the repo and run `install.sh`

Repo: [github.com/pxxkachu/dxp480t_arch](https://github.com/pxxkachu/dxp480t_arch)

```bash
pacman -Sy --needed git
git clone https://github.com/pxxkachu/dxp480t_arch.git /tmp/dxp480tp
cd /tmp/dxp480tp
bash install.sh
```

SSH clone (if you use GitHub SSH keys):

```bash
git clone git@github.com:pxxkachu/dxp480t_arch.git /tmp/dxp480tp
cd /tmp/dxp480tp
bash install.sh
```

**No git network access?** Copy the repo onto a second USB stick, mount it, and run from there:

```bash
mount /dev/sdX1 /mnt/usb    # use lsblk to find the stick
cd /mnt/usb/dxp480tp
bash install.sh
```

### What the installer prompts for

| Prompt | Example |
|--------|---------|
| OS disk | Pick the NVMe/SATA boot drive by number |
| EFI partition size | `512M` or `1G` |
| Data array disks | At least 2 remaining disks, space-separated numbers |
| Hostname | `dxp480tp` |
| Username | `admin` |
| Timezone | `America/Chicago` |
| Locale | `en_US.UTF-8` |
| Data array label | `media` |
| Data array mount point | `/media` |
| Password | root, then your user |
| Confirmation | type `ERASE` to destroy the selected disks |

The installer creates an ext4 root on the OS disk, a Btrfs RAID0 data pool (RAID1 metadata) on the data disks, systemd-boot, NetworkManager, OpenSSH, monthly scrub and daily snapshot timers, and zram swap. When it finishes, remove the install medium and reboot. Then continue with **Post-install** below (on the installed system).

---

## Post-install

Steps below run **after** the first successful boot into the installed system.

**SSH from Ghostty (macOS):** if `sudo` fails with `ncurses: cannot initialize terminal type ($TERM="xterm-ghostty")` or `Error opening terminal: xterm-ghostty`, add to `~/.bashrc`:

```bash
[[ "$TERM" == xterm-ghostty ]] && export TERM=xterm-256color
```

Then `source ~/.bashrc`, or one-shot: `sudo TERM=xterm-256color pacman -S …`

## Pre-flight checks

Verify the Btrfs data pool is mounted:

```bash
mountpoint /media
```

If not mounted:

```bash
sudo mount -t btrfs LABEL=media /media
```

## 1. Install and authenticate Tailscale

```bash
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

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

<Tailscale_IP>     <Tailscale_full_name> dxp480tp
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

The package creates user `qbt` and `/var/lib/qbittorrent` via sysusers/tmpfiles. Add it to the shared `media` group:

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
```
### Sonarr
```bash
sudo mkdir -p /etc/systemd/system/sonarr.service.d
sudo nano /etc/systemd/system/sonarr.service.d/override.conf

[Service]
Group=media
UMask=002
```
### Radarr
```bash
sudo mkdir -p /etc/systemd/system/radarr.service.d
sudo nano /etc/systemd/system/radarr.service.d/override.conf

[Service]
Group=media
UMask=002
```
### Prowlarr
```bash
sudo mkdir -p /etc/systemd/system/prowlarr.service.d
sudo nano /etc/systemd/system/prowlarr.service.d/override.conf

[Service]
Group=media
UMask=002
```

### Qui

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


## 13. Install Vaultwarden

Self-hosted Bitwarden-compatible password manager. Listens on localhost; HTTPS via Caddy in step 14 at `https://warden.lehaus.io` (covered by the Porkbun wildcard `*` record).

```bash
sudo pacman -S vaultwarden vaultwarden-web
```

The package creates user `vaultwarden` and `/var/lib/vaultwarden`. Configure:

```bash
sudo nano /etc/vaultwarden.env
```

```
DOMAIN=https://warden.lehaus.io
ROCKET_ADDRESS=127.0.0.1
ROCKET_PORT=8000
WEB_VAULT_ENABLED=true
WEB_VAULT_FOLDER=/usr/share/webapps/vaultwarden-web
DATA_FOLDER=/var/lib/vaultwarden
WEBSOCKET_ENABLED=false
SIGNUPS_ALLOWED=true
```

```bash
sudo chown vaultwarden:vaultwarden /var/lib/vaultwarden
sudo chmod 700 /var/lib/vaultwarden
sudo passwd --lock vaultwarden
sudo systemctl enable --now vaultwarden
curl -sI http://127.0.0.1:8000 | head -1
```

Create your account at `http://127.0.0.1:8000` on the NAS (or `https://warden.lehaus.io` after step 14). Then disable registration:

```bash
sudo nano /etc/vaultwarden.env
# SIGNUPS_ALLOWED=false
sudo systemctl restart vaultwarden
```

In Bitwarden clients, set **Server URL** to `https://warden.lehaus.io`.

Optional admin panel — run `sudo -u vaultwarden vaultwarden hash`, add `ADMIN_TOKEN=<PHC output>` to `/etc/vaultwarden.env`, restart, then open `https://warden.lehaus.io/admin` with the password you entered (not the PHC string).

Back up `/var/lib/vaultwarden` regularly (`db.sqlite3`, `rsa_key.pem`, `attachments/`). Use SQLite `.backup` while the service is running, or include the directory in btrfs snapshots (step 16).

## 14. Set up Caddy for HTTPS (`lehaus.io`)

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

Store credentials on the NAS (not in the Caddyfile). Config and secrets live under `/var/lib/caddy`:

```bash
sudo nano /var/lib/caddy/porkbun.env

PORKBUN_API_KEY=pk1_...
PORKBUN_SECRET_API_KEY=sk1_...
```

```bash
sudo chown caddy:caddy /var/lib/caddy/porkbun.env
sudo chmod 600 /var/lib/caddy/porkbun.env
```


### Create DNS records in Porkbun

| Type | Host | Answer | TTL |
|------|------|--------|-----|
| A | `*` | `<TS_IP>` | 600 |
| A | `pihole` | `<PI_TS_IP>` | 600 |

The wildcard covers NAS services (`qui.lehaus.io`, `qbit.lehaus.io`, `warden.lehaus.io`, `sonarr.lehaus.io`, etc.). The `pihole` record overrides the wildcard for `pihole.lehaus.io` only (`<PI_TS_IP>` = `tailscale ip -4` on **rpcmiv**).

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

warden.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:8000
}

plex.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:32400
}

start.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:3000
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

### HTTPS access (NAS)

| Service     | HTTPS URL                         |
|-------------|-----------------------------------|
| Qui         | `https://qui.lehaus.io`           |
| qBittorrent | `https://qbit.lehaus.io`          |
| Sonarr      | `https://sonarr.lehaus.io`        |
| Radarr      | `https://radarr.lehaus.io`        |
| Prowlarr    | `https://prowlarr.lehaus.io`      |
| autobrr     | `https://autobrr.lehaus.io`       |
| Vaultwarden | `https://warden.lehaus.io`        |
| Plex (web)  | `https://plex.lehaus.io/web`      |
| Homepage    | `https://start.lehaus.io`         |


### Plex (metadata web UI only)

Caddy gives you a consistent `lehaus.io` URL for editing library metadata in the browser. It is **not** a replacement for Plex remote access — leave **Settings → Remote Access** enabled and keep using Plex apps for watching (discovery and relay work as before).

`plex.lehaus.io` is covered by the wildcard `A` record; no Porkbun changes needed.

In Plex → **Settings → Network** (admin account):

1. **Custom server access URLs** — add (include `:443` so Plex does not assume port 32400):
   ```
   https://plex.lehaus.io:443
   ```
   This stops the web app from redirecting to `:32400` or the wrong host when you open the Caddy URL.
2. Leave **Remote access** enabled.

Open `https://plex.lehaus.io/web` from any tailnet device. Sign out and back in once if the web client still shows the old URL.

If you get **502 Bad Gateway**, Plex's self-signed cert on `:32400` is the usual cause — the Caddyfile block above must include `tls_insecure_skip_verify` in the `transport http` block. Verify from the NAS:

```bash
curl -sI http://127.0.0.1:32400/web | head -3
curl -skI https://127.0.0.1:32400/web | head -3
curl -sI https://plex.lehaus.io/web | head -5
sudo journalctl -u caddy -n 30 --no-pager
```

After editing `/var/lib/caddy/Caddyfile`, reload: `sudo systemctl reload caddy`.

**Do not** bind Plex to `127.0.0.1` in the [HTTPS-only lockdown](#enforce-https-only-recommended) below — remote access and client discovery need Plex listening on its normal interface.

### Enforce HTTPS-only (recommended)

After confirming HTTPS works, bind each service to `127.0.0.1` so it is only reachable through Caddy:

**qBittorrent** — in `/var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf`:

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

**Vaultwarden** — skip; `ROCKET_ADDRESS=127.0.0.1` in step 13.

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

## 15. Install Homepage dashboard (`start.lehaus.io`)

[Homepage](https://gethomepage.dev/) is a YAML-configured start page with live widgets for your *arr* stack, Pi-hole, qBittorrent, Plex, and Glances system stats on **dxp480tp** and **rpcmiv**. It runs natively on the NAS (no containers) and is served at `https://start.lehaus.io` through Caddy.

Vaultwarden is intentionally **not** on this dashboard — keep using `https://warden.lehaus.io` directly.

**Prerequisites:** step 14 complete (Caddy running, services bound to `127.0.0.1` if you applied HTTPS-only lockdown). On **rpcmiv**, complete [Glances for Homepage](#17-install-glances-for-homepage-dashboard) in [`rpcmiv/post_install.md`](../rpcmiv/post_install.md) so the Pi stats widget can reach `<PI_TS_IP>:61208`.

### Create the homepage user and directories

```bash
sudo useradd --system --home-dir /var/lib/homepage --shell /usr/bin/nologin homepage
sudo mkdir -p /var/lib/homepage/config /opt/homepage
sudo chown homepage:homepage /var/lib/homepage
sudo passwd --lock homepage
```

### Install Glances on dxp480tp

Glances exposes a local web API for CPU, memory, disk, and uptime. Homepage's built-in `resources` widget only sees the Homepage process filesystem — Glances is the correct way to show NAS and Pi host stats.

```bash
sudo pacman -S --needed glances iputils python-fastapi uvicorn
python -c "import fastapi, uvicorn; print('web deps ok')"
```

Install **both** `python-fastapi` and `uvicorn` — either one missing causes exit code **2** in `-w` mode. The one-liner must print `web deps ok` before enabling the service.

`iputils` provides ICMP ping if you use Homepage's `ping` property on any service.

```bash
sudo nano /etc/systemd/system/glances.service
```

```ini
[Unit]
Description=Glances web server (localhost)
After=network.target

[Service]
# Two dashes: --bind (not -bind)
ExecStart=/usr/bin/glances -w --bind 127.0.0.1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now glances
systemctl status glances
ss -tlnp | grep 61208
curl -sf http://127.0.0.1:61208/api/4/quicklook | head -c 80; echo
```

If `curl` prints nothing, check the service log — missing `python-fastapi` and/or `uvicorn` is the usual cause (exit code **2**):

```bash
sudo systemctl stop glances
sudo journalctl -u glances -n 30 --no-pager
/usr/bin/glances -w --bind 127.0.0.1
```

The foreground run prints `FastAPI import error` or `Uvicorn import error` if a package is still missing. Fix with `sudo pacman -S python-fastapi uvicorn`, re-run the `python -c` check, then `sudo systemctl start glances`.

**Exit code 2 but manual `glances -w --bind 127.0.0.1` works** — typo in the unit file. systemd must use `--bind` (two dashes). A single `-bind` makes Glances exit immediately with status 2:

```bash
grep ExecStart /etc/systemd/system/glances.service
# must show: ExecStart=/usr/bin/glances -w --bind 127.0.0.1
```

```bash
glances --version
curl -v http://127.0.0.1:61208/api/4/quicklook
```

On older Glances 3.x, try `/api/3/quicklook` instead and set `version: 3` in Homepage widgets. Arch extra currently ships Glances 4.x (`/api/4/...`).

### Build Homepage from source

**Run as your normal user — do NOT use sudo** for the clone, install, and build:

```bash
sudo pacman -S --needed nodejs npm git
sudo npm install -g pnpm
```

Pick a [release tag](https://github.com/gethomepage/homepage/releases) (example: `v1.13.2`):

```bash
git clone --depth 1 --branch v1.13.2 https://github.com/gethomepage/homepage.git /tmp/homepage-build
cd /tmp/homepage-build
pnpm install
pnpm build
```

Install the built app to `/opt/homepage` and link config to `/var/lib/homepage/config`:

```bash
sudo rsync -a --delete \
  --exclude config \
  /tmp/homepage-build/ /opt/homepage/
sudo cp -a /tmp/homepage-build/src/skeleton/. /var/lib/homepage/config/
sudo rm -rf /opt/homepage/config
sudo ln -s /var/lib/homepage/config /opt/homepage/config
sudo chown -R homepage:homepage /var/lib/homepage
sudo chown -R root:root /opt/homepage
sudo chmod -R a+rX /opt/homepage
rm -rf /tmp/homepage-build
```

To upgrade later: repeat the clone/build/rsync steps with a newer tag, then `sudo systemctl restart homepage`.

### Store API keys and secrets

Widget keys live in an env file, not in git-tracked YAML. Create:

```bash
sudo nano /var/lib/homepage/homepage.env
```

```bash
HOMEPAGE_VAR_SONARR_KEY=
HOMEPAGE_VAR_RADARR_KEY=
HOMEPAGE_VAR_PROWLARR_KEY=
HOMEPAGE_VAR_AUTOBRR_KEY=
HOMEPAGE_VAR_QBIT_USER=
HOMEPAGE_VAR_QBIT_PASS=
HOMEPAGE_VAR_PLEX_TOKEN=
HOMEPAGE_VAR_PIHOLE_KEY=
```

Fill in values:

| Variable | Where to get it |
|----------|-----------------|
| `HOMEPAGE_VAR_SONARR_KEY` | Sonarr → Settings → General → API Key |
| `HOMEPAGE_VAR_RADARR_KEY` | Radarr → Settings → General → API Key |
| `HOMEPAGE_VAR_PROWLARR_KEY` | Prowlarr → Settings → General → API Key |
| `HOMEPAGE_VAR_AUTOBRR_KEY` | autobrr → Settings → API Keys |
| `HOMEPAGE_VAR_QBIT_USER` / `PASS` | qBittorrent Web UI credentials |
| `HOMEPAGE_VAR_PLEX_TOKEN` | [Plex token](https://www.plexopedia.com/plex-media-server/general/plex-token/) |
| `HOMEPAGE_VAR_PIHOLE_KEY` | Pi-hole app password or API key (`<PI_TS_IP>` on rpcmiv) |

Reference secrets in YAML as `{{HOMEPAGE_VAR_SONARR_KEY}}`, etc.

```bash
sudo chown homepage:homepage /var/lib/homepage/homepage.env
sudo chmod 600 /var/lib/homepage/homepage.env
```

### Configure Homepage

Edit the three main config files under `/var/lib/homepage/config/`. Replace `<PI_TS_IP>` with `tailscale ip -4` output from **rpcmiv**.

**`settings.yaml`** — minimal global settings:

```yaml
title: lehaus.io
theme: dark
color: zinc
headerStyle: boxedWidgets
statusStyle: dot
```

**`widgets.yaml`** — host stats (top bar):

```yaml
- glances:
    label: dxp480tp
    url: http://127.0.0.1:61208
    version: 4
    cpu: true
    mem: true
    uptime: true
    disk:
      - /
      - /media
    expanded: true

- glances:
    label: rpcmiv
    url: http://<PI_TS_IP>:61208
    version: 4
    cpu: true
    mem: true
    uptime: true
    disk: /
    expanded: true
```

**`services.yaml`** — service groups (Vaultwarden omitted on purpose):

```yaml
- DNS:
    - Pi-hole:
        icon: pi-hole.png
        href: https://pihole.lehaus.io
        siteMonitor: https://pihole.lehaus.io/admin/
        widget:
          type: pihole
          url: http://<PI_TS_IP>
          version: 6
          key: {{HOMEPAGE_VAR_PIHOLE_KEY}}

- Download:
    - qBittorrent:
        icon: qbittorrent.png
        href: https://qbit.lehaus.io
        siteMonitor: http://127.0.0.1:8080
        widget:
          type: qbittorrent
          url: http://127.0.0.1:8080
          username: {{HOMEPAGE_VAR_QBIT_USER}}
          password: {{HOMEPAGE_VAR_QBIT_PASS}}
    - Qui:
        icon: qui.png
        href: https://qui.lehaus.io
        siteMonitor: http://127.0.0.1:7476
    - autobrr:
        icon: autobrr.png
        href: https://autobrr.lehaus.io
        siteMonitor: http://127.0.0.1:7474
        widget:
          type: autobrr
          url: http://127.0.0.1:7474
          key: {{HOMEPAGE_VAR_AUTOBRR_KEY}}

- Library:
    - Prowlarr:
        icon: prowlarr.png
        href: https://prowlarr.lehaus.io
        siteMonitor: http://127.0.0.1:9696
        widget:
          type: prowlarr
          url: http://127.0.0.1:9696
          key: {{HOMEPAGE_VAR_PROWLARR_KEY}}
    - Sonarr:
        icon: sonarr.png
        href: https://sonarr.lehaus.io
        siteMonitor: http://127.0.0.1:8989
        widget:
          type: sonarr
          url: http://127.0.0.1:8989
          key: {{HOMEPAGE_VAR_SONARR_KEY}}
          enableQueue: true
    - Radarr:
        icon: radarr.png
        href: https://radarr.lehaus.io
        siteMonitor: http://127.0.0.1:7878
        widget:
          type: radarr
          url: http://127.0.0.1:7878
          key: {{HOMEPAGE_VAR_RADARR_KEY}}

- Media:
    - Plex:
        icon: plex.png
        href: https://plex.lehaus.io/web
        siteMonitor: http://127.0.0.1:32400/web
        widget:
          type: plex
          url: http://127.0.0.1:32400
          key: {{HOMEPAGE_VAR_PLEX_TOKEN}}
```

Widget URLs use `http://127.0.0.1:...` because Homepage runs on the NAS and talks to backends directly (same as Caddy upstreams). `siteMonitor` uses those internal URLs so health checks work after HTTPS-only lockdown. User-facing links use `https://*.lehaus.io`.

There is no official Caddy widget — infer Caddy health from green `siteMonitor` dots on proxied services.

```bash
sudo chown -R homepage:homepage /var/lib/homepage/config
```

### systemd unit for Homepage

Homepage listens on localhost only; Caddy terminates TLS at `start.lehaus.io`.

```bash
sudo nano /etc/systemd/system/homepage.service
```

```ini
[Unit]
Description=Homepage dashboard
After=network-online.target tailscaled.service glances.service
Wants=network-online.target

[Service]
Type=simple
User=homepage
Group=homepage
WorkingDirectory=/opt/homepage
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOMEPAGE_ALLOWED_HOSTS=start.lehaus.io
EnvironmentFile=/var/lib/homepage/homepage.env
ExecStart=/usr/bin/node /opt/homepage/node_modules/next/dist/bin/next start -H 127.0.0.1 -p 3000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Add the Caddy block if you have not already (also shown in step 14):

```caddyfile
start.lehaus.io {
    import tailnet
    reverse_proxy 127.0.0.1:3000
}
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homepage
sudo systemctl reload caddy
systemctl status homepage glances
```

Open `https://start.lehaus.io` from a tailnet device. Click the refresh icon (bottom-right) after editing YAML.

Check logs if widgets show API errors:

```bash
sudo journalctl -u homepage -f
tail -f /var/lib/homepage/config/logs/homepage.log
```

**rpcmiv Glances widget empty** — confirm Glances on the Pi is running and bound to `<PI_TS_IP>` (rpcmiv step 17), and that `<PI_TS_IP>` in `widgets.yaml` matches `tailscale ip -4` on the Pi.

**Host validation error** — ensure `HOMEPAGE_ALLOWED_HOSTS=start.lehaus.io` matches the browser URL exactly (see [Homepage docs](https://gethomepage.dev/installation/#homepage_allowed_hosts)).

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

## 17. (Future) Add backup SSD with btrfs send/receive

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
