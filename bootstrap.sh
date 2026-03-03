#!/bin/bash
# ============================================================
# Knobert Arm Bootstrap
# "One curl to join the octopus"
#
# Usage:
#   BRIDGE_KEY=your-key bash <(curl -fsSL https://knobesq.github.io/knobert-arm/bootstrap.sh)
#
# Or with options:
#   BRIDGE_KEY=key INSTANCE_ID=my-arm MODEL=haiku bash <(curl -fsSL ...)
#
# The only secret is BRIDGE_KEY. Everything else is discovered.
# ============================================================
set -euo pipefail

# --- Config (only BRIDGE_KEY is required) ---
BRIDGE_KEY="${BRIDGE_KEY:?ERROR: Set BRIDGE_KEY environment variable}"
INSTANCE_ID="${INSTANCE_ID:-knobert-$(hostname | tr '.' '-')-$$}"
MODEL="${MODEL:-}"  # empty = auto-select based on task complexity
DOCKER_IMAGE="${DOCKER_IMAGE:-knobesq/knobert-harness:latest}"
RESTART_DELAY="${RESTART_DELAY:-30}"

# --- Discover bridge URL from this repo ---
REPO_BASE="https://raw.githubusercontent.com/knobesq/knobert-arm/main"
BRIDGE_URL=$(curl -fsSL "${REPO_BASE}/bridge-url.txt" 2>/dev/null || echo "")

if [ -z "$BRIDGE_URL" ]; then
  echo "ERROR: Could not fetch bridge URL from ${REPO_BASE}/bridge-url.txt"
  exit 1
fi

echo "============================================"
echo "  Knobert Arm Bootstrap"
echo "  Instance: ${INSTANCE_ID}"
echo "  Image:    ${DOCKER_IMAGE}"
echo "  Bridge:   ${BRIDGE_URL:0:60}..."
echo "============================================"

# --- Pull latest harness ---
echo "Pulling latest harness image..."
docker pull "${DOCKER_IMAGE}"

# --- Build live image from harness output ---
BUILD_DIR=$(mktemp -d)
docker run --rm "${DOCKER_IMAGE}" --role worker > "${BUILD_DIR}/Dockerfile"
docker build --no-cache -t knobert:live "${BUILD_DIR}/"
rm -rf "${BUILD_DIR}"

# --- Run worker loop (auto-restart on exit) ---
echo "Starting worker loop..."
while true; do
  docker rm -f "${INSTANCE_ID}" 2>/dev/null || true

  docker run --rm \
    --name "${INSTANCE_ID}" \
    -e KNOBERT_ROLE=worker \
    -e KNOBERT_INSTANCE_ID="${INSTANCE_ID}" \
    -e GAS_BRIDGE_URL="${BRIDGE_URL}" \
    -e GAS_BRIDGE_KEY="${BRIDGE_KEY}" \
    -e PYTHONUNBUFFERED=1 \
    ${MODEL:+-e WORKER_MODEL="${MODEL}"} \
    -v knobert-home:/home/knobert \
    --tmpfs /tmp:size=512m \
    knobert:live \
    || true

  echo "[$(date)] Worker exited. Restarting in ${RESTART_DELAY}s..."
  sleep "${RESTART_DELAY}"

  # Re-check for updated bridge URL on restart
  NEW_URL=$(curl -fsSL "${REPO_BASE}/bridge-url.txt" 2>/dev/null || echo "")
  if [ -n "$NEW_URL" ] && [ "$NEW_URL" != "$BRIDGE_URL" ]; then
    echo "Bridge URL updated: ${NEW_URL:0:60}..."
    BRIDGE_URL="$NEW_URL"
  fi

  # Pull latest image on restart
  echo "Pulling latest image..."
  docker pull "${DOCKER_IMAGE}" || true
  docker run --rm "${DOCKER_IMAGE}" --role worker > /tmp/knobert-df-$$ 2>/dev/null && \
    docker build -t knobert:live -f /tmp/knobert-df-$$ . 2>/dev/null && \
    rm -f /tmp/knobert-df-$$ || true
done
