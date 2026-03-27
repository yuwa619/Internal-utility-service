#!/usr/bin/env bash
# =============================================================================
# rollback.sh — Blue-Green Rollback Script
#
# Reverts the running container to the previously deployed version by:
#   1. Reading the previous colour, port, and image tag written by deploy.sh
#   2. Restarting the old container with the previous image
#   3. Waiting for it to pass the health check
#   4. Switching Nginx upstream back to the old port
#   5. Stopping the current (broken) container
#
# Usage (on the EC2 instance):
#   sudo bash /opt/internal-utility-service/scripts/rollback.sh
# =============================================================================

set -euo pipefail

APP_DIR="/opt/internal-utility-service"
NGINX_CONF="/etc/nginx/sites-available/internal-utility-service"
COLOR_FILE="${APP_DIR}/ACTIVE_COLOR"
ENV_FILE="${APP_DIR}/.env"
HEALTH_RETRIES=30
HEALTH_SLEEP=2

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
    fail "Health check timed out — rollback failed."
}

# ---------------------------------------------------------------------------
# Read rollback metadata written by deploy.sh
# ---------------------------------------------------------------------------
[[ -f "${APP_DIR}/PREVIOUS_IMAGE" ]] || fail "No previous image on record. Cannot rollback."
[[ -f "${APP_DIR}/PREVIOUS_COLOR" ]] || fail "No previous colour on record. Cannot rollback."
[[ -f "${APP_DIR}/PREVIOUS_PORT"  ]] || fail "No previous port on record. Cannot rollback."

ROLLBACK_IMAGE=$(cat "${APP_DIR}/PREVIOUS_IMAGE")
ROLLBACK_COLOR=$(cat "${APP_DIR}/PREVIOUS_COLOR")
ROLLBACK_PORT=$(cat  "${APP_DIR}/PREVIOUS_PORT")
CURRENT_COLOR=$(cat  "${COLOR_FILE}")

log "Rolling back from ${CURRENT_COLOR} → ${ROLLBACK_COLOR} using image ${ROLLBACK_IMAGE}"

# ---------------------------------------------------------------------------
# Restart the previous container with the previous image
# ---------------------------------------------------------------------------
docker rm -f "internal-utility-${ROLLBACK_COLOR}" 2>/dev/null || true

docker run -d \
    --name "internal-utility-${ROLLBACK_COLOR}" \
    --restart unless-stopped \
    -p "${ROLLBACK_PORT}:5000" \
    --env-file "${ENV_FILE}" \
    "${ROLLBACK_IMAGE}"

wait_for_health "${ROLLBACK_PORT}"

# ---------------------------------------------------------------------------
# Switch Nginx upstream back to the previous port
# ---------------------------------------------------------------------------
log "Switching Nginx upstream to port ${ROLLBACK_PORT}"
sudo sed -i "s|server 127.0.0.1:[0-9]*;|server 127.0.0.1:${ROLLBACK_PORT};|" \
    "${NGINX_CONF}"
sudo nginx -t || fail "Nginx config test failed — not reloading."
sudo nginx -s reload

# ---------------------------------------------------------------------------
# Stop the current (broken) container
# ---------------------------------------------------------------------------
docker stop "internal-utility-${CURRENT_COLOR}" 2>/dev/null || true
docker rm   "internal-utility-${CURRENT_COLOR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Update state file
# ---------------------------------------------------------------------------
echo "${ROLLBACK_COLOR}" > "${COLOR_FILE}"

log "Rollback complete.  Now serving: ${ROLLBACK_COLOR} on port ${ROLLBACK_PORT}."
