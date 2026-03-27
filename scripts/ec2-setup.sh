#!/usr/bin/env bash
# =============================================================================
# ec2-setup.sh — One-time EC2 Instance Provisioning Script
#
# Run this script ONCE on a fresh Ubuntu 22.04 (or Amazon Linux 2023) EC2
# instance to install all dependencies and configure the host environment.
#
# Prerequisites:
#   • EC2 instance has an IAM Role with secretsmanager:GetSecretValue
#     on the secret used by the application (least-privilege).
#   • Security Group allows inbound 22 (SSH), 80 (HTTP), 443 (HTTPS).
#     All other inbound traffic should be blocked.
#
# Usage (as ubuntu / ec2-user, with sudo):
#   chmod +x ec2-setup.sh && sudo bash ec2-setup.sh
# =============================================================================

set -euo pipefail

APP_DIR="/opt/internal-utility-service"
NGINX_CONF="/etc/nginx/sites-available/internal-utility-service"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# 1. System updates
# ---------------------------------------------------------------------------
log "Updating system packages ..."
apt-get update -y
apt-get upgrade -y

# ---------------------------------------------------------------------------
# 2. Install Docker
# ---------------------------------------------------------------------------
log "Installing Docker ..."
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group (avoids sudo for docker commands)
usermod -aG docker ubuntu

log "Docker installed: $(docker --version)"

# ---------------------------------------------------------------------------
# 3. Install Nginx
# ---------------------------------------------------------------------------
log "Installing Nginx ..."
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx

# ---------------------------------------------------------------------------
# 4. Install Certbot (Let's Encrypt)
# ---------------------------------------------------------------------------
log "Installing Certbot ..."
apt-get install -y snapd
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# ---------------------------------------------------------------------------
# 5. Install Git and clone the application repository
# ---------------------------------------------------------------------------
log "Cloning application repository ..."
apt-get install -y git

mkdir -p "${APP_DIR}"
git clone https://github.com/yuwa619/Internal-utility-service.git "${APP_DIR}" \
    || (cd "${APP_DIR}" && git pull origin main)

chmod +x "${APP_DIR}/scripts/"*.sh

# ---------------------------------------------------------------------------
# 6. Create the .env file (fill in real values before running deploy.sh)
# ---------------------------------------------------------------------------
if [[ ! -f "${APP_DIR}/.env" ]]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    log "Created ${APP_DIR}/.env from .env.example — EDIT THIS FILE with real secrets."
fi

# ---------------------------------------------------------------------------
# 7. Configure Nginx reverse proxy
# ---------------------------------------------------------------------------
log "Configuring Nginx ..."
cp "${APP_DIR}/nginx/nginx.conf" "${NGINX_CONF}"

# Disable the default site
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 8. Initialise active-colour state file (start with blue on port 5001)
# ---------------------------------------------------------------------------
echo "blue" > "${APP_DIR}/ACTIVE_COLOR"

# ---------------------------------------------------------------------------
# 9. Configure SSL with Certbot
#    Uncomment and replace YOUR_DOMAIN once DNS points to this instance.
# ---------------------------------------------------------------------------
# log "Obtaining Let's Encrypt certificate ..."
# certbot --nginx -d YOUR_DOMAIN --non-interactive --agree-tos -m YOUR_EMAIL
# systemctl enable certbot.timer   # auto-renewal

# ---------------------------------------------------------------------------
# 10. Set up automatic certificate renewal (cron fallback)
# ---------------------------------------------------------------------------
(crontab -l 2>/dev/null; \
    echo "0 3 * * * /usr/bin/certbot renew --quiet && nginx -s reload") \
    | crontab -

log "EC2 setup complete."
log "Next steps:"
log "  1. Edit ${APP_DIR}/.env with real secret values."
log "  2. Add YOUR_DOMAIN to nginx/nginx.conf and run Certbot."
log "  3. Push to main on GitHub — the CI/CD pipeline will deploy automatically."
