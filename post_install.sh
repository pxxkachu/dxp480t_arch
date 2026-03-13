#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Post-install script for Arch NAS (UGREEN DXP480T Plus)
# Sets up Tailscale, qBittorrent, Sonarr, Radarr, Prowlarr
# Must be run as root via: sudo bash post_install.sh
# -----------------------------

LOG_FILE="/var/log/post_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to $LOG_FILE"

# ---- Pre-flight checks ----

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (sudo)."
  exit 1
fi

REAL_USER="${SUDO_USER:?ERROR: Run this script with 'sudo', not as a root login.}"

if ! id "$REAL_USER" &>/dev/null; then
  echo "ERROR: User '$REAL_USER' does not exist."
  exit 1
fi

if fuser /var/lib/pacman/db.lck &>/dev/null 2>&1; then
  echo "ERROR: pacman database is locked. Another package manager may be running."
  exit 1
fi

echo "== Pre-flight: Checking network connectivity =="
if ! curl -sf --max-time 5 https://archlinux.org >/dev/null 2>&1; then
  echo "ERROR: No internet connectivity. Cannot reach archlinux.org."
  exit 1
fi
echo "  Network OK."

echo "== Pre-flight: Checking /media mount =="
if ! mountpoint -q /media; then
  echo "ERROR: /media is not a mount point. Is the Btrfs data pool mounted?"
  echo "  Check with: mount | grep /media"
  echo "  Mount with: mount -t btrfs LABEL=media /media"
  exit 1
fi
echo "  /media is mounted."

MEDIA_GROUP="media"
APPS=(qbittorrent sonarr radarr prowlarr)

# ============================================================
# Step 1: Install and authenticate Tailscale
# ============================================================
echo ""
echo "== Step 1: Installing Tailscale =="
pacman -S --needed --noconfirm tailscale

echo "== Enabling tailscaled service =="
systemctl enable --now tailscaled

if tailscale status &>/dev/null 2>&1; then
  echo "  Tailscale is already authenticated."
else
  echo "== Authenticating with Tailscale =="
  echo "A login URL will appear below. Open it in a browser to authenticate."
  echo ""
  tailscale up
fi

echo ""
echo "== Waiting for Tailscale to connect =="
TS_IP=""
for i in $(seq 1 60); do
  if tailscale status &>/dev/null; then
    TS_IP="$(tailscale ip -4 2>/dev/null || true)"
    if [[ -n "$TS_IP" ]]; then
      echo "  Tailscale connected. IP: $TS_IP"
      break
    fi
  fi
  if [[ $i -eq 60 ]]; then
    echo "ERROR: Tailscale did not connect after 60 seconds."
    exit 1
  fi
  sleep 1
done

FULL_FQDN="$(tailscale status --self --json | grep -oP '"DNSName"\s*:\s*"\K[^"]+' | sed 's/\.$//')"
CURRENT_HOSTNAME="$(cat /etc/hostname)"

if [[ -z "$FULL_FQDN" ]]; then
  echo "ERROR: Could not determine Tailscale FQDN."
  echo "  Verify with: tailscale status --self --json"
  exit 1
fi

echo "  Tailscale FQDN: $FULL_FQDN"

# ============================================================
# Step 2: Update /etc/hosts with Tailscale info
# ============================================================
echo ""
echo "== Step 2: Updating /etc/hosts =="
cp /etc/hosts /etc/hosts.bak
echo "  Backed up /etc/hosts to /etc/hosts.bak"

cat <<EOF > /etc/hosts
127.0.0.1   localhost
127.0.1.1   ${CURRENT_HOSTNAME}.localdomain ${CURRENT_HOSTNAME}

::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

${TS_IP}    ${FULL_FQDN} ${CURRENT_HOSTNAME}
EOF
echo "  /etc/hosts updated with Tailscale IP and FQDN."

# ============================================================
# Step 3: Create media group and service accounts
# ============================================================
# Must happen BEFORE AUR package installs — sonarr-bin, radarr-bin,
# prowlarr-bin ship sysusers files that auto-create accounts with their
# own default groups. Creating ours first with primary group 'media'
# prevents that; sysusers skips users that already exist.
echo ""
echo "== Step 3: Creating media group and service accounts =="

if ! getent group "$MEDIA_GROUP" &>/dev/null; then
  groupadd "$MEDIA_GROUP"
  echo "  Created group: $MEDIA_GROUP"
else
  echo "  Group '$MEDIA_GROUP' already exists."
fi

for app in "${APPS[@]}"; do
  if ! id "$app" &>/dev/null; then
    useradd --system --no-create-home --home-dir /dev/null \
      --shell /usr/bin/nologin --gid "$MEDIA_GROUP" "$app"
    passwd --lock "$app" &>/dev/null
    echo "  Created and locked service account: $app"
  else
    usermod --gid "$MEDIA_GROUP" "$app"
    echo "  Service account '$app' already exists — set primary group to $MEDIA_GROUP."
  fi
done

echo "  Adding $REAL_USER to $MEDIA_GROUP group..."
usermod -aG "$MEDIA_GROUP" "$REAL_USER"
echo "  $REAL_USER added to $MEDIA_GROUP."

# ============================================================
# Step 4: Install qBittorrent
# ============================================================
echo ""
echo "== Step 4: Installing qBittorrent =="
pacman -S --needed --noconfirm qbittorrent-nox

# ============================================================
# Step 5: Install paru (AUR helper)
# ============================================================
echo ""
echo "== Step 5: Installing paru =="
if command -v paru &>/dev/null; then
  echo "  paru is already installed, skipping."
else
  echo "  Building paru-bin as user '$REAL_USER'..."
  rm -rf /tmp/paru-bin
  sudo -u "$REAL_USER" bash -c '
    set -euo pipefail
    git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
    cd /tmp/paru-bin
    makepkg -si --noconfirm
  '
  rm -rf /tmp/paru-bin
  if ! command -v paru &>/dev/null; then
    echo "ERROR: paru installation failed."
    exit 1
  fi
  echo "  paru installed."
fi

# ============================================================
# Step 6: Install Sonarr, Radarr, Prowlarr (AUR)
# ============================================================
echo ""
echo "== Step 6: Installing Sonarr, Radarr, Prowlarr from AUR =="
sudo -u "$REAL_USER" paru -S --needed --noconfirm sonarr-bin radarr-bin prowlarr-bin
echo "  AUR packages installed."

# ============================================================
# Step 7: Create service data and media directories
# ============================================================
echo ""
echo "== Step 7: Creating service data directories =="
for app in "${APPS[@]}"; do
  mkdir -p "/var/lib/$app"
  chown "$app:$MEDIA_GROUP" "/var/lib/$app"
  chmod 775 "/var/lib/$app"
  echo "  /var/lib/$app -> $app:$MEDIA_GROUP (775)"
done

echo ""
echo "== Step 7b: Creating media directories =="
mkdir -p /media/downloads/{pending,complete,torrents}
mkdir -p /media/{movies,shows}

chown qbittorrent:$MEDIA_GROUP /media/downloads /media/downloads/{pending,complete,torrents}
chown root:$MEDIA_GROUP /media/movies /media/shows

chmod 2775 /media/downloads /media/downloads/{pending,complete,torrents}
chmod 2775 /media/movies /media/shows

echo "  /media/downloads/pending   -> qbittorrent:$MEDIA_GROUP"
echo "  /media/downloads/complete  -> qbittorrent:$MEDIA_GROUP"
echo "  /media/downloads/torrents  -> qbittorrent:$MEDIA_GROUP"
echo "  /media/movies              -> root:$MEDIA_GROUP"
echo "  /media/shows               -> root:$MEDIA_GROUP"
echo "  All directories set to 2775 (setgid)"

# ============================================================
# Step 8: Create systemd service files
# ============================================================
echo ""
echo "== Step 8: Configuring systemd services =="

# qBittorrent — no vendor service file shipped, create from scratch
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
echo "  Created qbittorrent.service"

# Sonarr, Radarr, Prowlarr — AUR packages ship their own service files;
# use drop-in overrides to set our group and umask without replacing them.
for app in sonarr radarr prowlarr; do
  mkdir -p "/etc/systemd/system/${app}.service.d"
  cat > "/etc/systemd/system/${app}.service.d/override.conf" <<EOF
[Service]
Group=$MEDIA_GROUP
UMask=002
EOF
  echo "  Created ${app}.service.d/override.conf (Group=$MEDIA_GROUP, UMask=002)"
done

# ============================================================
# Step 9: Start all services
# ============================================================
echo ""
echo "== Step 9: Starting services =="
systemctl daemon-reload

FAILED_SERVICES=()
for app in "${APPS[@]}"; do
  systemctl enable --now "$app"
  sleep 2
  if systemctl is-active --quiet "$app"; then
    echo "  $app: running"
  else
    echo "  WARNING: $app failed to start. Check: journalctl -u $app -n 30"
    FAILED_SERVICES+=("$app")
  fi
done

# ============================================================
# Done
# ============================================================
echo ""
echo "========================================"
echo "  POST-INSTALL COMPLETE"
echo "========================================"
echo ""
echo "  Log file:       $LOG_FILE"
echo "  Tailscale IP:   $TS_IP"
echo "  Tailscale FQDN: $FULL_FQDN"

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
  echo ""
  echo "  WARNING: These services failed to start: ${FAILED_SERVICES[*]}"
  echo "  Debug with: journalctl -u <service> -n 50"
fi

echo ""
echo "  Next steps:"
echo ""
echo "  1. Log out and back in (so $REAL_USER picks up the '$MEDIA_GROUP' group)"
echo ""
echo "  2. Configure URL bases in each app's web UI:"
echo ""
echo "     Sonarr      http://${TS_IP}:8989   -> Set URL Base to /sonarr"
echo "     Radarr      http://${TS_IP}:7878   -> Set URL Base to /radarr"
echo "     Prowlarr    http://${TS_IP}:9696   -> Set URL Base to /prowlarr"
echo "     qBittorrent http://${TS_IP}:8080   -> Set WebUI path to /qbittorrent"
echo ""
echo "  3. Restart services after setting URL bases:"
echo "     sudo systemctl restart qbittorrent sonarr radarr prowlarr"
echo ""
echo "  4. Set up Tailscale Serve (HTTPS reverse proxy):"
echo "     tailscale serve --https=443 --bg --set-path /sonarr http://127.0.0.1:8989"
echo "     tailscale serve --https=443 --bg --set-path /radarr http://127.0.0.1:7878"
echo "     tailscale serve --https=443 --bg --set-path /prowlarr http://127.0.0.1:9696"
echo "     tailscale serve --https=443 --bg --set-path /qbittorrent http://127.0.0.1:8080"
echo ""
echo "  5. Access via HTTPS: https://${FULL_FQDN}/sonarr"
echo ""
