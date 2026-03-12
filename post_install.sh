#!/usr/bin/env bash
set -euo pipefail

# --- PRE-FLIGHT CHECKS ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)."
  exit 1
fi

REAL_USER="${SUDO_USER:?ERROR: Please run this script with 'sudo', not as a root login.}"

HOSTNAME=$(hostname)
read -r -p "Enter the name of your media group (e.g., media): " MEDIA_GROUP_NAME

if ! command -v paru >/dev/null 2>&1; then
    echo "ERROR: paru not found. Please install paru before running this script."
    exit 1
fi

if ! getent group "$MEDIA_GROUP_NAME" >/dev/null; then
    echo "Creating group: $MEDIA_GROUP_NAME"
    groupadd "$MEDIA_GROUP_NAME"
fi

echo "== Step 1: Creating Service Accounts =="
APPS=("qbittorrent" "sonarr" "radarr" "prowlarr")

for user in "${APPS[@]}"; do
    if ! id "$user" &>/dev/null; then
        echo "Creating service account: $user"
        useradd -r -M -g "$MEDIA_GROUP_NAME" -s /usr/bin/nologin "$user"
    else
        echo "User $user already exists, skipping..."
    fi
done

echo "== Step 2: Installing Packages (Official & AUR) =="
pacman -S --needed --noconfirm nginx jq qbittorrent-nox tailscale

sudo -u "$REAL_USER" paru -S --needed --noconfirm sonarr-bin radarr-bin prowlarr-bin

echo "== Step 3: Configuring Tailscale =="
systemctl enable --now tailscaled

echo "----------------------------------------------------------------"
echo "Please click the link below to authenticate your NAS to Tailscale:"
tailscale up
echo "----------------------------------------------------------------"

TS_IP=$(tailscale ip -4)
FULL_FQDN=$(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')

echo "Detected Tailscale IP: $TS_IP"
echo "Detected Full FQDN: $FULL_FQDN"

echo "== Step 4: Configuring /etc/hosts =="
cp /etc/hosts /etc/hosts.bak
cat <<EOF > /etc/hosts
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
${TS_IP}    ${FULL_FQDN} ${HOSTNAME}
EOF

echo "== Step 5: Creating Service Data Directories =="
for app in "${APPS[@]}"; do
    mkdir -p "/var/lib/$app"
    chown "$app:${MEDIA_GROUP_NAME}" "/var/lib/$app"
    chmod 775 "/var/lib/$app"
done

echo "== Step 6: Creating Systemd Service Files =="

cat <<EOF > /etc/systemd/system/qbittorrent.service
[Unit]
Description=qBittorrent-nox service
After=network.target

[Service]
Type=simple
User=qbittorrent
Group=${MEDIA_GROUP_NAME}
UMask=002
Environment="HOME=/var/lib/qbittorrent"
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

for app in sonarr radarr prowlarr; do
    cat <<EOF > /etc/systemd/system/${app}.service
[Unit]
Description=${app^} Daemon
After=network.target

[Service]
User=$app
Group=${MEDIA_GROUP_NAME}
UMask=002
Type=simple
ExecStart=/usr/bin/$app -nobrowser -data=/var/lib/$app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
done

echo "== Step 7: Generating Tailscale SSL Certificate =="
mkdir -p /etc/nginx/certs
tailscale cert --cert-file /etc/nginx/certs/nas.crt --key-file /etc/nginx/certs/nas.key "$FULL_FQDN"
chmod 600 /etc/nginx/certs/nas.key

echo "== Step 8: Configuring Nginx Reverse Proxy =="
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat <<EOF > /etc/nginx/sites-available/nas.conf
server {
    listen 80;
    server_name ${FULL_FQDN} ${HOSTNAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${FULL_FQDN} ${HOSTNAME};

    ssl_certificate     /etc/nginx/certs/nas.crt;
    ssl_certificate_key /etc/nginx/certs/nas.key;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";

    location /sonarr      { proxy_pass http://127.0.0.1:8989; }
    location /radarr      { proxy_pass http://127.0.0.1:7878; }
    location /prowlarr    { proxy_pass http://127.0.0.1:9696; }
    location /qbittorrent/ { proxy_pass http://127.0.0.1:8080/; }
}
EOF

if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    include sites-enabled/*;' /etc/nginx/nginx.conf
fi

ln -sf /etc/nginx/sites-available/nas.conf /etc/nginx/sites-enabled/nas.conf

echo "== Step 9: Starting All Services =="
systemctl daemon-reload
systemctl enable --now qbittorrent sonarr radarr prowlarr nginx

echo "================================================================"
echo "SETUP COMPLETE"
echo "1. Set URL Bases in GUIs via IP:Port (e.g., http://${TS_IP}:8989)"
echo "2. Restart services: sudo systemctl restart qbittorrent sonarr radarr prowlarr"
echo "3. Access via HTTPS: https://${FULL_FQDN}/sonarr"
echo "================================================================"
