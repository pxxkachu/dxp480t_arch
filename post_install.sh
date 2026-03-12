#!/usr/bin/env bash
set -euo pipefail

# --- INTERACTIVE CONFIGURATION ---
read -r -p "Enter your Tailscale Domain (e.g., tail342cb.ts.net): " DOMAIN
read -r -p "Enter your Tailscale IP (e.g., 100.65.244.75): " TS_IP

HOSTNAME="kintoun"
MEDIA_GROUP="media"

echo "== Configuring /etc/hosts =="
cat <<EOF > /etc/hosts
# IPv4 Local
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}

# IPv6 Local
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

# Tailscale Address
${TS_IP}    ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF

echo "== Creating Service Data Directories in /var/lib =="
for app in qbittorrent sonarr radarr prowlarr; do
    mkdir -p "/var/lib/$app"
    chown "$app:${MEDIA_GROUP}" "/var/lib/$app"
    chmod 775 "/var/lib/$app"
done

echo "== Creating Systemd Service Files =="

# qBittorrent Service
cat <<EOF > /etc/systemd/system/qbittorrent.service
[Unit]
Description=qBittorrent-nox service
After=network.target

[Service]
Type=simple
User=qbittorrent
Group=${MEDIA_GROUP}
UMask=002
Environment="HOME=/var/lib/qbittorrent"
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Template for *Arr Services
for app in sonarr radarr prowlarr; do
    cat <<EOF > /etc/systemd/system/${app}.service
[Unit]
Description=${app^} Daemon
After=network.target

[Service]
User=$app
Group=${MEDIA_GROUP}
UMask=002
Type=simple
ExecStart=/usr/bin/$app -nobrowser -data=/var/lib/$app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
done

echo "== Generating Tailscale SSL Certificate =="
mkdir -p /etc/nginx/certs
tailscale cert --cert-file /etc/nginx/certs/nas.crt --key-file /etc/nginx/certs/nas.key "${HOSTNAME}.${DOMAIN}"
chmod 600 /etc/nginx/certs/nas.key

echo "== Configuring Nginx Reverse Proxy (HTTPS) =="
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat <<EOF > /etc/nginx/sites-available/nas.conf
server {
    listen 80;
    server_name ${HOSTNAME}.${DOMAIN} ${HOSTNAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${HOSTNAME}.${DOMAIN} ${HOSTNAME};

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

[ -f /etc/nginx/sites-enabled/nas.conf ] || ln -s /etc/nginx/sites-available/nas.conf /etc/nginx/sites-enabled/nas.conf

echo "== Starting Services =="
systemctl daemon-reload
systemctl enable --now qbittorrent sonarr radarr prowlarr nginx

echo "== Setup Complete! =="
echo "Note: You MUST access apps via IP:Port first to set the 'URL Base' in settings."
echo "Example: http://${TS_IP}:8989/ (Sonarr)"
