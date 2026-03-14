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

Back up and rewrite. Replace `<HOSTNAME>`, `<TS_IP>`, and `<FQDN>` with your values.

```bash
sudo nano /etc/hosts
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

Run as your normal user, not root:

```bash
sudo rm -rf /tmp/paru-bin
git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
cd /tmp/paru-bin
makepkg -si --noconfirm
cd -
sudo rm -rf /tmp/paru-bin
```

## 6. Install Sonarr, Radarr, Prowlarr (AUR)

Run as your normal user, not root:

```bash
sudo paru -S -sonarr-bin radarr-bin prowlarr-bin
```

## 7. Add admin user to media group

Switch back to root (`sudo -i`) for the remaining steps.

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
sudo cat <<'EOF' > /etc/systemd/system/qbittorrent-nox@qbt.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

### Sonarr, Radarr, Prowlarr

```bash
sudo mkdir -p /etc/systemd/system/sonarr.service.d
sudo cat <<'EOF' > /etc/systemd/system/sonarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

```bash
sudo mkdir -p /etc/systemd/system/radarr.service.d
sudo cat <<'EOF' > /etc/systemd/system/radarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

```bash
sudo mkdir -p /etc/systemd/system/prowlarr.service.d
sudo cat <<'EOF' > /etc/systemd/system/prowlarr.service.d/override.conf
[Service]
Group=media
UMask=002
EOF
```

## 11. Start all services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qbittorrent-nox@qbt sonarr radarr prowlarr
```

Verify they're running:

```bash
sudo systemctl status qbittorrent-nox@qbt sonarr radarr prowlarr
```

Get qBittorrent's initial admin password from its journal:

```bash
journalctl -u qbittorrent-nox@qbt -n 20 | grep -i password
```

## 12. Configure URL bases

Each app needs its URL base set so Tailscale Serve path-based routing works.

Open each web UI directly by IP:

| Service      | Direct URL                  | Setting location                           | Set URL Base to  |
|--------------|-----------------------------|------------------------------------------- |------------------|
| Sonarr       | `http://<TS_IP>:8989`       | Settings > General > URL Base              | `/sonarr`        |
| Radarr       | `http://<TS_IP>:7878`       | Settings > General > URL Base              | `/radarr`        |
| Prowlarr     | `http://<TS_IP>:9696`       | Settings > General > URL Base              | `/prowlarr`      |
| qBittorrent  | `http://<TS_IP>:8080`       | Options > Web UI > Alternative Web UI Path | `/qbittorrent`   |

Restart after changing:

```bash
systemctl restart qbittorrent-nox@qbt sonarr radarr prowlarr
```

## 13. Set up Tailscale Serve (HTTPS reverse proxy)

Tailscale Serve terminates TLS automatically using Tailscale-managed certificates — no cert files to generate or renew.

```bash
tailscale serve --https=443 --bg --set-path /sonarr http://127.0.0.1:8989
tailscale serve --https=443 --bg --set-path /radarr http://127.0.0.1:7878
tailscale serve --https=443 --bg --set-path /prowlarr http://127.0.0.1:9696
tailscale serve --https=443 --bg --set-path /qbittorrent http://127.0.0.1:8080
```

Verify the configuration:

```bash
tailscale serve status
```

Access everything over HTTPS from any device on your tailnet:

```
https://<FQDN>/sonarr
https://<FQDN>/radarr
https://<FQDN>/prowlarr
https://<FQDN>/qbittorrent
```

To remove a path later:

```bash
tailscale serve --https=443 --remove --set-path /sonarr
```
