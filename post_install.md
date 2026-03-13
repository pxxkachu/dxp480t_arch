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

### qBittorrent

The package ships a template service, but we create a simple non-template unit:

```bash
cat <<'EOF' > /etc/systemd/system/qbittorrent-nox.service
[Unit]
Description=qBittorrent-nox
After=network.target

[Service]
Type=simple
User=qbt
Group=media
UMask=002
Environment="HOME=/var/lib/qbt"
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

### Sonarr, Radarr, Prowlarr

These AUR packages ship their own service files. Use drop-in overrides to set the group and umask without replacing the vendor units (so package updates flow through):

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
systemctl enable --now qbittorrent-nox sonarr radarr prowlarr
```

Verify they're running:

```bash
systemctl status qbittorrent-nox sonarr radarr prowlarr
```

Get qBittorrent's initial admin password from its journal:

```bash
journalctl -u qbittorrent-nox -n 20 | grep -i password
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
systemctl restart qbittorrent-nox sonarr radarr prowlarr
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
