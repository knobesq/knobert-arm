#!/bin/bash
# ============================================================
# Knobert Arm Bootstrap
# "One curl to join the octopus"
#
# Usage:
#   BRIDGE_KEY=your-key bash <(curl -fsSL https://knobesq.github.io/knobert-arm/bootstrap.sh)
#
# The only secret is BRIDGE_KEY. Everything else is discovered.
# The image is a generic runtime — source code is cloned from
# the private GitHub repo at startup. Arms are fully ephemeral.
# ============================================================
set -euo pipefail

BRIDGE_KEY="${BRIDGE_KEY:?ERROR: Set BRIDGE_KEY environment variable}"
INSTANCE_ID="${INSTANCE_ID:-knobert-$(hostname | tr '.' '-')-$$}"
MODEL="${MODEL:-}"
DOCKER_IMAGE="${DOCKER_IMAGE:-knobesq/knobert-harness:latest}"
RESTART_DELAY="${RESTART_DELAY:-30}"

echo "============================================"
echo "  Knobert Arm Bootstrap"
echo "  Instance: ${INSTANCE_ID}"
echo "  Image:    ${DOCKER_IMAGE}"
echo "============================================"

# --- Always start fresh ---
echo "Cleaning stale images..."
docker rmi "${DOCKER_IMAGE}" 2>/dev/null || true

echo "Pulling latest runtime image..."
docker pull "${DOCKER_IMAGE}"

# --- Run worker loop (auto-restart on exit) ---
echo "Starting worker loop..."
while true; do
  docker rm -f "${INSTANCE_ID}" 2>/dev/null || true

  # Fully ephemeral — no volumes, no host state.
  # The container clones code from GitHub and syncs data from Drive at startup.
  docker run --rm \
    --name "${INSTANCE_ID}" \
    -e GAS_BRIDGE_KEY="${BRIDGE_KEY}" \
    -e KNOBERT_ROLE=worker \
    -e KNOBERT_INSTANCE_ID="${INSTANCE_ID}" \
    -e PYTHONUNBUFFERED=1 \
    ${MODEL:+-e WORKER_MODEL="${MODEL}"} \
    --tmpfs /tmp:size=512m \
    "${DOCKER_IMAGE}" \
    || true

  echo "[$(date)] Worker exited. Restarting in ${RESTART_DELAY}s..."
  sleep "${RESTART_DELAY}"

  # Pull latest image on restart
  echo "Pulling latest image..."
  docker rmi "${DOCKER_IMAGE}" 2>/dev/null || true
  docker pull "${DOCKER_IMAGE}" || true
done
