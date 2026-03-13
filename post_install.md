# Post-Install: Arch NAS (UGREEN DXP480T Plus)

Headless media server setup with qBittorrent, Sonarr, Radarr, Prowlarr, and Tailscale Serve (HTTPS reverse proxy).

All commands assume root (`sudo -i`) unless noted otherwise.

---

## 1. Create the media group and service accounts

Replace `media` with your preferred group name if different.

```bash
groupadd media
```

```bash
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media qbittorrent
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media sonarr
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media radarr
useradd --system --no-create-home --home-dir /dev/null --shell /usr/bin/nologin --gid media prowlarr
passwd --lock qbittorrent
passwd --lock sonarr
passwd --lock radarr
passwd --lock prowlarr
```

## 2. Install paru (AUR helper)

Run as your normal user, not root:

```bash
sudo pacman -S --needed base-devel git
git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
cd /tmp/paru-bin
makepkg -si --noconfirm
cd -
```

## 3. Install packages

Official repos:

```bash
sudo pacman -S --needed qbittorrent-nox tailscale
```

AUR packages (run as your normal user, not root):

```bash
paru -S --needed sonarr-bin radarr-bin prowlarr-bin
```

## 4. Set up Tailscale

```bash
systemctl enable --now tailscaled
tailscale up
```

Follow the printed authentication link to register the NAS.

After authenticating, note your Tailscale IP and FQDN:

```bash
tailscale ip -4
tailscale whois --self | grep 'Name:'
```

Store these for the steps below — referred to as `<TS_IP>` and `<FQDN>` (e.g., `100.x.x.x` and `kintoun.tail342cb.ts.net`).

## 5. Update /etc/hosts

Back up the current file, then overwrite it. Replace `<HOSTNAME>`, `<TS_IP>`, and `<FQDN>` with your values.

```bash
cp /etc/hosts /etc/hosts.bak
```

```bash
cat <<EOF > /etc/hosts
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

## 6. Create service data directories

```bash
mkdir -p /var/lib/{qbittorrent,sonarr,radarr,prowlarr}
chown qbittorrent:media /var/lib/qbittorrent
chown sonarr:media      /var/lib/sonarr
chown radarr:media      /var/lib/radarr
chown prowlarr:media    /var/lib/prowlarr
chmod 775 /var/lib/{qbittorrent,sonarr,radarr,prowlarr}
```

## 7. Create systemd service files

### qBittorrent

```bash
cat <<'EOF' > /etc/systemd/system/qbittorrent.service
[Unit]
Description=qBittorrent
After=network.target

[Service]
Type=simple
User=qbittorrent
Group=media
UMask=002
Environment="HOME=/var/lib/qbittorrent"
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

### Sonarr

```bash
cat <<'EOF' > /etc/systemd/system/sonarr.service
[Unit]
Description=Sonarr
After=network.target

[Service]
User=sonarr
Group=media
UMask=002
Type=simple
ExecStart=/usr/bin/sonarr -nobrowser -data=/var/lib/sonarr
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

### Radarr

```bash
cat <<'EOF' > /etc/systemd/system/radarr.service
[Unit]
Description=Radarr
After=network.target

[Service]
User=radarr
Group=media
UMask=002
Type=simple
ExecStart=/usr/bin/radarr -nobrowser -data=/var/lib/radarr
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

### Prowlarr

```bash
cat <<'EOF' > /etc/systemd/system/prowlarr.service
[Unit]
Description=Prowlarr
After=network.target

[Service]
User=prowlarr
Group=media
UMask=002
Type=simple
ExecStart=/usr/bin/prowlarr -nobrowser -data=/var/lib/prowlarr
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

## 8. Start services

```bash
systemctl daemon-reload
systemctl enable --now qbittorrent sonarr radarr prowlarr
```

## 9. Configure URL bases

Before setting up Tailscale Serve, each app needs its URL base configured so path-based routing works.

Open each web UI directly by IP:

| Service      | Direct URL                  | Setting location                          | Set URL Base to  |
|--------------|-----------------------------|-------------------------------------------|------------------|
| Sonarr       | `http://<TS_IP>:8989`       | Settings > General > URL Base             | `/sonarr`        |
| Radarr       | `http://<TS_IP>:7878`       | Settings > General > URL Base             | `/radarr`        |
| Prowlarr     | `http://<TS_IP>:9696`       | Settings > General > URL Base             | `/prowlarr`      |
| qBittorrent  | `http://<TS_IP>:8080`       | Options > Web UI > Alternative Web UI Path| `/qbittorrent`   |

Restart after changing:

```bash
systemctl restart qbittorrent sonarr radarr prowlarr
```

## 10. Set up Tailscale Serve (HTTPS reverse proxy)

Tailscale Serve terminates TLS automatically using Tailscale-managed certificates — no cert files to generate or renew.

Enable HTTPS mode first:

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
