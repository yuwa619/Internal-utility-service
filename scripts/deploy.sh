#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Blue-Green Deployment Script
#
# Strategy:
#   Two containers run on different host ports:
#     Blue  → host port 5001  (container name: internal-utility-blue)
#     Green → host port 5002  (container name: internal-utility-green)
#
#   Nginx upstream always points to exactly ONE of these ports.
#   On every deploy:
#     1. Pull the latest image from Docker Hub
#     2. Determine which colour is currently INACTIVE
#     3. Start the inactive colour with the new image
#     4. Wait up to 60 s for its /health endpoint to return 200
#     5. Rewrite the Nginx upstream to the new port and reload Nginx
#     6. Stop and remove the old container
#     7. Record the new active colour in /opt/internal-utility-service/ACTIVE_COLOR
#
# Rollback: run rollback.sh — it reverses step 5 and restarts the old image.
#
# Required env vars (injected by GitHub Actions deploy job):
#   DOCKERHUB_USERNAME   Docker Hub account name
#
# Usage:
#   DOCKERHUB_USERNAME=yuwa619 bash scripts/deploy.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
APP_DIR="/opt/internal-utility-service"
IMAGE="${DOCKERHUB_USERNAME}/internal-utility-service:latest"
COLOR_FILE="${APP_DIR}/ACTIVE_COLOR"
ENV_FILE="${APP_DIR}/.env"
HEALTH_RETRIES=30
HEALTH_SLEEP=2

# Nginx config — bootstrap.conf is copied here on first deploy by ci.yml.
# Certbot may later rewrite this file to add SSL; the upstream block persists.
NGINX_CONF="/etc/nginx/nginx.conf"

# Use sudo for docker if the current user isn't in the docker group yet
# (group membership only takes effect on next login after first bootstrap)
if docker ps &>/dev/null 2>&1; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

wait_for_health() {
    local port=$1
    log "Waiting for health check on port ${port} ..."
    for i in $(seq 1 "${HEALTH_RETRIES}"); do
        if curl -sf "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            log "Health check passed after ${i} attempt(s)."
            return 0
        fi
        sleep "${HEALTH_SLEEP}"
    done
    fail "Health check failed after $((HEALTH_RETRIES * HEALTH_SLEEP)) seconds."
}

# ---------------------------------------------------------------------------
# Determine active / inactive colour
# ---------------------------------------------------------------------------
ACTIVE_COLOR=$(cat "${COLOR_FILE}" 2>/dev/null || echo "blue")

if [[ "${ACTIVE_COLOR}" == "blue" ]]; then
    NEW_COLOR="green"
    NEW_PORT=5002
    OLD_COLOR="blue"
    OLD_PORT=5001
else
    NEW_COLOR="blue"
    NEW_PORT=5001
    OLD_COLOR="green"
    OLD_PORT=5002
fi

log "Active: ${ACTIVE_COLOR} (port ${OLD_PORT})  →  Deploying: ${NEW_COLOR} (port ${NEW_PORT})"

# ---------------------------------------------------------------------------
# Step 1: Pull the new image
# ---------------------------------------------------------------------------
log "Pulling image: ${IMAGE}"
$DOCKER pull "${IMAGE}"

# ---------------------------------------------------------------------------
# Step 2: Start the inactive colour
# ---------------------------------------------------------------------------
log "Starting container: internal-utility-${NEW_COLOR}"
$DOCKER rm -f "internal-utility-${NEW_COLOR}" 2>/dev/null || true

$DOCKER run -d \
    --name "internal-utility-${NEW_COLOR}" \
    --restart unless-stopped \
    -p "${NEW_PORT}:5000" \
    --env-file "${ENV_FILE}" \
    "${IMAGE}"

# ---------------------------------------------------------------------------
# Step 3: Wait for the new container to become healthy
# ---------------------------------------------------------------------------
wait_for_health "${NEW_PORT}"

# ---------------------------------------------------------------------------
# Step 4: Save the previous image tag for rollback
# ---------------------------------------------------------------------------
PREVIOUS_IMAGE=$($DOCKER inspect --format='{{.Config.Image}}' \
    "internal-utility-${OLD_COLOR}" 2>/dev/null || echo "${IMAGE}")
echo "${PREVIOUS_IMAGE}" > "${APP_DIR}/PREVIOUS_IMAGE"
echo "${OLD_COLOR}"       > "${APP_DIR}/PREVIOUS_COLOR"
echo "${OLD_PORT}"        > "${APP_DIR}/PREVIOUS_PORT"

# ---------------------------------------------------------------------------
# Step 5: Switch Nginx upstream to the new port
# ---------------------------------------------------------------------------
log "Switching Nginx upstream to port ${NEW_PORT}"
sudo sed -i "s|server 127.0.0.1:[0-9]*;|server 127.0.0.1:${NEW_PORT};|" \
    "${NGINX_CONF}"
sudo nginx -t || fail "Nginx config test failed — not reloading."
sudo nginx -s reload
log "Nginx reloaded — traffic now routed to ${NEW_COLOR} (port ${NEW_PORT})."

# ---------------------------------------------------------------------------
# Step 6: Stop and remove the old container
# ---------------------------------------------------------------------------
log "Stopping old container: internal-utility-${OLD_COLOR}"
$DOCKER stop "internal-utility-${OLD_COLOR}" 2>/dev/null || true
$DOCKER rm   "internal-utility-${OLD_COLOR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 7: Record new active colour
# ---------------------------------------------------------------------------
echo "${NEW_COLOR}" > "${COLOR_FILE}"

log "Deployment complete.  Active: ${NEW_COLOR} on port ${NEW_PORT}."

# Prune old images to keep the host clean
$DOCKER image prune -f --filter "until=48h" || true
