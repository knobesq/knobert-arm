#!/bin/bash
# ============================================================
# Knobert Armstrap
# "One curl to join the octopus"
#
# Usage (Docker mode — default):
#   BRIDGE_KEY=key bash <(curl -fsSL https://knobesq.github.io/knobert-arm/armstrap.sh)
#
# Usage (Bare-metal mode — no Docker needed):
#   BRIDGE_KEY=key MODE=bare bash <(curl -fsSL https://knobesq.github.io/knobert-arm/armstrap.sh)
#
# The only secret is BRIDGE_KEY. Everything else is discovered.
# ============================================================
set -euo pipefail

ARMSTRAP_VERSION="2026.03.05.6"  # Bump this on every change

BRIDGE_KEY="${BRIDGE_KEY:?ERROR: Set BRIDGE_KEY environment variable}"
MODE="${MODE:-docker}"  # docker | bare
ROLE="${ROLE:-worker}"  # worker | secondary-head | head
INSTANCE_ID="${INSTANCE_ID:-knobert-$(hostname | tr '.' '-')-$$}"
MODEL="${MODEL:-}"
RESTART_DELAY="${RESTART_DELAY:-30}"

# Docker image registries — ghcr.io primary (no pull rate limits), Docker Hub fallback
GHCR_IMAGE="ghcr.io/knobesq/knobert-harness:latest"
HUB_IMAGE="knobesq/knobert-harness:latest"
DOCKER_IMAGE="${DOCKER_IMAGE:-${GHCR_IMAGE}}"

# Exponential backoff state
BACKOFF_FILE="/tmp/knobert-armstrap-backoff"
MAX_BACKOFF=3600  # 1 hour cap

echo "============================================"
echo "  Knobert Armstrap v${ARMSTRAP_VERSION}"
echo "  Instance: ${INSTANCE_ID}"
echo "  Role:     ${ROLE}"
echo "  Mode:     ${MODE}"
[ "${MODE}" = "docker" ] && echo "  Image:    ${DOCKER_IMAGE}"
echo "  OS:       $(uname -s -r 2>/dev/null || echo unknown)"
echo "  Python:   $(python3 --version 2>/dev/null || echo missing)"
echo "  User:     $(whoami)@$(hostname)"
echo "  Home:     ${HOME}"
echo "============================================"

# --- Exponential backoff helpers ---
get_backoff_delay() {
  if [ -f "${BACKOFF_FILE}" ]; then
    cat "${BACKOFF_FILE}"
  else
    echo "0"
  fi
}

record_failure() {
  local current
  current=$(get_backoff_delay)
  if [ "${current}" -eq 0 ]; then
    echo "60" > "${BACKOFF_FILE}"  # Start at 1 minute
  else
    local next=$(( current * 2 ))
    [ "${next}" -gt "${MAX_BACKOFF}" ] && next="${MAX_BACKOFF}"
    echo "${next}" > "${BACKOFF_FILE}"
  fi
  echo "[$(date)] Failure recorded. Next backoff: $(cat "${BACKOFF_FILE}")s"
}

clear_backoff() {
  rm -f "${BACKOFF_FILE}"
}

wait_backoff() {
  local delay
  delay=$(get_backoff_delay)
  if [ "${delay}" -gt 0 ]; then
    echo "[$(date)] Backing off for ${delay}s (previous failures)..."
    sleep "${delay}"
  fi
}

# --- Docker pull with registry fallback ---
pull_image() {
  # Try ghcr.io first (no rate limits for public images)
  echo "Pulling from ghcr.io..."
  if docker pull "${GHCR_IMAGE}" 2>/dev/null; then
    DOCKER_IMAGE="${GHCR_IMAGE}"
    clear_backoff
    return 0
  fi

  # Fallback to Docker Hub
  echo "ghcr.io failed, trying Docker Hub..."
  if docker pull "${HUB_IMAGE}" 2>/dev/null; then
    DOCKER_IMAGE="${HUB_IMAGE}"
    clear_backoff
    return 0
  fi

  # Both failed
  echo "[$(date)] ERROR: All registries failed."
  record_failure
  return 1
}

# --- Check if image exists locally ---
have_image() {
  docker image inspect "${GHCR_IMAGE}" &>/dev/null && DOCKER_IMAGE="${GHCR_IMAGE}" && return 0
  docker image inspect "${HUB_IMAGE}" &>/dev/null && DOCKER_IMAGE="${HUB_IMAGE}" && return 0
  docker image inspect "knobert:latest" &>/dev/null && DOCKER_IMAGE="knobert:latest" && return 0
  return 1
}

# ============================================================
# BARE-METAL MODE — no Docker, just git clone + python3
# ============================================================
run_bare() {
  local KNOBERT_DIR="${HOME}/knobert"
  local BRIDGE_URL

  echo "[bare] Discovering bridge URL..."
  BRIDGE_URL=$(curl -fsSL https://knobesq.github.io/knobert-arm/bridge-url.txt 2>/dev/null || echo "")
  if [ -z "${BRIDGE_URL}" ]; then
    echo "ERROR: Could not discover bridge URL"
    exit 1
  fi

  echo "[bare] Fetching configuration from bridge..."
  local CONFIG
  # NOTE: GAS web apps redirect GET→HTML (doGet), POST goes to doPost.
  # Do NOT use -X POST — it causes curl to reissue the redirect as GET (RFC 2616).
  # Using -d alone is enough: curl infers POST from the body AND keeps POST through
  # the 302 redirect to script.googleusercontent.com.
  CONFIG=$(curl -sL "${BRIDGE_URL}" \
    -H "Content-Type: application/json" \
    --data "{\"action\":\"config.get\",\"key\":\"${BRIDGE_KEY}\"}" 2>/dev/null || echo "{}")

  # Extract GitHub token — nested under "config" key in bridge response
  local GITHUB_TOKEN
  GITHUB_TOKEN=$(echo "${CONFIG}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('config',{}).get('GITHUB_TOKEN', d.get('GITHUB_TOKEN','')))" 2>/dev/null || echo "")

  # Clone or update the repo
  if [ -d "${KNOBERT_DIR}/.git" ]; then
    echo "[bare] Updating existing repo..."
    cd "${KNOBERT_DIR}" && git pull --ff-only 2>/dev/null || true
  else
    echo "[bare] Cloning knobert repo..."
    if [ -n "${GITHUB_TOKEN}" ]; then
      git clone "https://${GITHUB_TOKEN}@github.com/knobesq/knobert.git" "${KNOBERT_DIR}"
    else
      git clone git@github.com:knobesq/knobert.git "${KNOBERT_DIR}"
    fi
  fi

  cd "${KNOBERT_DIR}"

  # ── Post-clone provisioning ──────────────────────────────────────
  # The daemon looks for config files at BOTH ~/lib/ and ~/knobert/lib/.
  # Write to the repo's lib/ AND create ~/lib/ symlinks so paths resolve
  # regardless of whether HOME/lib or HOME/knobert/lib is referenced.
  echo "[bare] Provisioning config files..."

  # Write bridge config to repo lib/
  echo "${BRIDGE_URL}" > lib/gas-bridge-url.txt
  echo "${BRIDGE_KEY}" > lib/gas-bridge-key.txt

  # Extract MQTT credentials from config (nested under "config" key)
  for key in KNOBERT_MQTT_HOST KNOBERT_MQTT_USER KNOBERT_MQTT_PASS; do
    local val
    val=$(echo "${CONFIG}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('config',d)
print(c.get('${key}',''))" 2>/dev/null || echo "")
    if [ -n "${val}" ]; then
      local fname
      case "${key}" in
        KNOBERT_MQTT_HOST) fname="hivemq-host.txt" ;;
        KNOBERT_MQTT_USER) fname="hivemq-user.txt" ;;
        KNOBERT_MQTT_PASS) fname="hivemq-pass.txt" ;;
      esac
      echo "${val}" > "lib/${fname}"
    fi
  done

  # Ensure ~/lib/ exists and has the config files too.
  # The daemon's gas-bridge.py looks at HOME/lib/, not HOME/knobert/lib/.
  # If ~/lib is not the repo's lib, symlink or copy the config files there.
  if [ "${KNOBERT_DIR}/lib" != "${HOME}/lib" ]; then
    mkdir -p "${HOME}/lib"
    for cfg in gas-bridge-url.txt gas-bridge-key.txt gas-bridge.py bridge.py \
               hivemq-host.txt hivemq-user.txt hivemq-pass.txt \
               groq-api-key.txt neil-sms-gateway.txt; do
      if [ -f "${KNOBERT_DIR}/lib/${cfg}" ]; then
        ln -sf "${KNOBERT_DIR}/lib/${cfg}" "${HOME}/lib/${cfg}" 2>/dev/null || \
          cp -f "${KNOBERT_DIR}/lib/${cfg}" "${HOME}/lib/${cfg}" 2>/dev/null || true
      fi
    done
    echo "[bare] Config files symlinked to ~/lib/"
  fi

  # Extract and store Groq API key if available
  local GROQ_KEY
  GROQ_KEY=$(echo "${CONFIG}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('config',d)
print(c.get('GROQ_API_KEY',''))" 2>/dev/null || echo "")
  if [ -n "${GROQ_KEY}" ]; then
    echo "${GROQ_KEY}" > lib/groq-api-key.txt
    echo "[bare] Groq API key provisioned"
  fi

  # ── Ensure PATH includes user-local bins ────────────────────────
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:/usr/local/bin:${PATH}"

  # ── Install Python dependencies ────────────────────────────────
  # Ubuntu 24.04 uses PEP 668 "externally managed" Python — try --user first, then
  # --break-system-packages as a fallback. Either way, never let a pip failure stop startup.
  echo "[bare] Installing Python dependencies..."
  python3 -c "import paho.mqtt" 2>/dev/null || \
    python3 -m pip install paho-mqtt --user --quiet 2>/dev/null || \
    python3 -m pip install paho-mqtt --break-system-packages --quiet 2>/dev/null || \
    true

  python3 -c "import markdown" 2>/dev/null || \
    python3 -m pip install markdown --user --quiet 2>/dev/null || \
    python3 -m pip install markdown --break-system-packages --quiet 2>/dev/null || \
    true

  # ── Install Claude Code (the task executor) ────────────────────
  # Workers execute tasks via `claude -p`. Install if missing.
  if ! command -v claude &>/dev/null; then
    echo "[bare] Claude Code not found. Installing..."
    # Need Node.js first
    if ! command -v node &>/dev/null; then
      echo "[bare] Installing Node.js..."
      if command -v apt-get &>/dev/null; then
        # Ubuntu/Debian: install via NodeSource
        curl -fsSL https://deb.nodesource.com/setup_22.x 2>/dev/null | sudo -n bash - 2>/dev/null || true
        sudo -n apt-get install -y nodejs 2>/dev/null || true
      fi
    fi
    if command -v npm &>/dev/null; then
      echo "[bare] Installing Claude Code via npm..."
      npm install -g @anthropic-ai/claude-code 2>/dev/null || \
        sudo -n npm install -g @anthropic-ai/claude-code 2>/dev/null || \
        { mkdir -p "${HOME}/.npm-global" && \
          npm config set prefix "${HOME}/.npm-global" && \
          npm install -g @anthropic-ai/claude-code 2>/dev/null; } || \
        true
    fi
    if command -v claude &>/dev/null; then
      echo "[bare] Claude Code installed: $(claude --version 2>/dev/null || echo 'unknown version')"
    else
      echo "[bare] WARNING: Claude Code not available — tasks will fail"
    fi
  else
    echo "[bare] Claude Code: $(claude --version 2>/dev/null || echo 'present')"
  fi

  # ── Propagate Bedrock credentials for Claude Code ──────────────
  # Claude Code on arms uses Bedrock via the pay-i proxy, same as the head.
  # Extract from bridge config if available.
  for key in ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_CUSTOM_HEADERS \
             CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_SKIP_BEDROCK_AUTH \
             ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL; do
    local val
    val=$(echo "${CONFIG}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('config',d)
print(c.get('${key}',''))" 2>/dev/null || echo "")
    if [ -n "${val}" ]; then
      export "${key}=${val}"
      echo "[bare] ${key} configured"
    fi
  done

  echo "[bare] Starting as ${ROLE}..."
  export KNOBERT_ROLE="${ROLE}"
  export KNOBERT_INSTANCE_ID="${INSTANCE_ID}"
  export PYTHONUNBUFFERED=1
  export GAS_BRIDGE_URL="${BRIDGE_URL}"
  export GAS_BRIDGE_KEY="${BRIDGE_KEY}"

  # ── Signal handling: forward to child, clean exit ──────────────
  CHILD_PID=""
  cleanup() {
    echo "[$(date)] Shutting down (signal received)..."
    [ -n "${CHILD_PID}" ] && kill "${CHILD_PID}" 2>/dev/null
    wait "${CHILD_PID}" 2>/dev/null
    exit 0
  }
  trap cleanup SIGINT SIGTERM

  # Dispatch based on role — worker runs the task poller, head runs the daemon.
  # One brain, many tentacles. Arms sense and execute, they don't think.
  case "${ROLE}" in
    worker)
      while true; do
        echo "[$(date)] Starting worker..."
        python3 lib/knobert-worker.py &
        CHILD_PID=$!
        wait "${CHILD_PID}" || true
        CHILD_PID=""
        echo "[$(date)] Worker exited. Restarting in ${RESTART_DELAY}s..."
        sleep "${RESTART_DELAY}" &
        CHILD_PID=$!
        wait "${CHILD_PID}" 2>/dev/null || true
        CHILD_PID=""
        git pull --ff-only 2>/dev/null || true
      done
      ;;
    head|secondary-head)
      export KNOBERT_HEAD_MODE="${ROLE}"
      [ "${ROLE}" = "secondary-head" ] && export KNOBERT_HEAD_MODE="secondary"
      while true; do
        echo "[$(date)] Starting daemon (${ROLE})..."
        python3 lib/knobert-daemon.py &
        CHILD_PID=$!
        wait "${CHILD_PID}" || true
        CHILD_PID=""
        echo "[$(date)] Daemon exited. Restarting in ${RESTART_DELAY}s..."
        sleep "${RESTART_DELAY}" &
        CHILD_PID=$!
        wait "${CHILD_PID}" 2>/dev/null || true
        CHILD_PID=""
        git pull --ff-only 2>/dev/null || true
      done
      ;;
    *)
      echo "ERROR: Unknown ROLE '${ROLE}'. Use 'worker', 'head', or 'secondary-head'."
      exit 1
      ;;
  esac
}

# ============================================================
# DOCKER MODE — container-based arm
# ============================================================
run_docker() {
  # Initial pull (or use local image)
  if ! have_image; then
    echo "No local image found. Pulling..."
    wait_backoff
    if ! pull_image; then
      echo "ERROR: Could not pull image. Will retry with backoff."
      # Still try to enter the loop — maybe image appears later
    fi
  else
    echo "Using local image: ${DOCKER_IMAGE}"
  fi

  # Run worker loop with exponential backoff on failures
  local consecutive_failures=0

  while true; do
    docker rm -f "${INSTANCE_ID}" 2>/dev/null || true

    if ! have_image; then
      echo "[$(date)] No image available. Waiting..."
      wait_backoff
      pull_image || { record_failure; continue; }
    fi

    echo "[$(date)] Starting container (${ROLE})..."
    docker run --rm \
      --name "${INSTANCE_ID}" \
      -e GAS_BRIDGE_KEY="${BRIDGE_KEY}" \
      -e KNOBERT_ROLE="${ROLE}" \
      -e KNOBERT_INSTANCE_ID="${INSTANCE_ID}" \
      -e PYTHONUNBUFFERED=1 \
      ${MODEL:+-e WORKER_MODEL="${MODEL}"} \
      --tmpfs /tmp:size=512m \
      "${DOCKER_IMAGE}" \
      && consecutive_failures=0 \
      || consecutive_failures=$(( consecutive_failures + 1 ))

    # Exponential backoff on consecutive failures
    if [ "${consecutive_failures}" -gt 0 ]; then
      local delay=$(( RESTART_DELAY * (2 ** (consecutive_failures - 1)) ))
      [ "${delay}" -gt "${MAX_BACKOFF}" ] && delay="${MAX_BACKOFF}"
      echo "[$(date)] Container failed (${consecutive_failures}x). Waiting ${delay}s..."
      sleep "${delay}"
    else
      echo "[$(date)] Container exited cleanly. Restarting in ${RESTART_DELAY}s..."
      sleep "${RESTART_DELAY}"
    fi

    # Try to refresh image (with backoff protection)
    pull_image 2>/dev/null || true
  done
}

# ============================================================
# Main
# ============================================================
case "${MODE}" in
  bare)   run_bare ;;
  docker) run_docker ;;
  *)
    echo "ERROR: Unknown MODE '${MODE}'. Use 'docker' or 'bare'."
    exit 1
    ;;
esac
