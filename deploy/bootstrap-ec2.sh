#!/usr/bin/env bash
# EC2 user-data: runs once, as root, on first boot of a freshly launched
# instance (via cloud-init). Not used on an already-running instance — the
# CI pipeline's "provision" job only passes this to `aws ec2 run-instances`
# when it creates a new instance; an existing, reused instance never re-runs
# this. Safe to also run by hand on a box that was launched some other way,
# except the `git clone` step (see note below).
set -euo pipefail
exec > /var/log/replit-porject-bootstrap.log 2>&1

REPO_URL="https://github.com/SatyamMauryakit/Replit_porject.git"
APP_DIR="/home/ubuntu/Replit_porject"

echo "=== $(date --iso-8601=seconds) bootstrap starting ==="

apt-get update
apt-get install -y ca-certificates curl gnupg nginx certbot python3-certbot-nginx git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/ubuntu' \
  "Suites: $(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" \
  'Components: stable' \
  "Architectures: $(dpkg --print-architecture)" \
  'Signed-By: /etc/apt/keyrings/docker.gpg' \
  > /etc/apt/sources.list.d/docker.sources

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
systemctl enable --now nginx
usermod -aG docker ubuntu

# This repo is public, so a plain clone needs no credential. If this script
# is ever reused for a private repo, this is the one line that would need a
# token/deploy key.
if [ ! -d "$APP_DIR/.git" ]; then
  sudo -u ubuntu git clone "$REPO_URL" "$APP_DIR"
fi
chmod +x "$APP_DIR/deploy/deploy.sh"

rm -f /etc/nginx/sites-enabled/default

mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/developer-portfolio-upstream.conf <<'NGINX_UPSTREAM'
proxy_pass http://127.0.0.1:18080;
NGINX_UPSTREAM

cat > /etc/nginx/sites-available/developer-portfolio <<'NGINX_SITE'
server {
    listen 80;
    listen [::]:80;
    server_name _;

    client_max_body_size 5m;

    location / {
        include /etc/nginx/snippets/developer-portfolio-upstream.conf;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
NGINX_SITE

ln -sf /etc/nginx/sites-available/developer-portfolio /etc/nginx/sites-enabled/developer-portfolio
nginx -t
systemctl reload nginx

echo "=== $(date --iso-8601=seconds) bootstrap complete ==="
