#!/usr/bin/env bash
set -euo pipefail

# Ensure secrets we create are not world-readable.
umask 077

gen_random_32() {
  local s=""
  if command -v openssl >/dev/null 2>&1; then
    s=$(openssl rand -base64 48 2>/dev/null | tr -d '=+/\n ' | cut -c1-32 || true)
  fi
  if [[ -z "$s" && -r /dev/urandom ]]; then
    s=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)
  fi
  if [[ -z "$s" ]]; then
    s=$(for _ in $(seq 1 32); do printf "%X" $((RANDOM % 16)); done)
  fi
  while [[ ${#s} -lt 32 ]]; do
    s+=$(printf "%X" $((RANDOM % 16)))
  done
  echo "${s:0:32}"
}

gen_strong_password_32() {
  # 32 chars, must include upper+lower+digit; no spaces.
  local base=""
  if [[ -r /dev/urandom ]]; then
    base=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 28 || true)
  fi
  if [[ ${#base} -lt 28 ]]; then
    base=$(gen_random_32 | cut -c1-28)
  fi

  # Ensure complexity.
  echo "${base}Aa0B" | cut -c1-32
}

usage() {
  cat <<'EOF'
Usage:
  ./start-linux.sh [--configs-dir DIR] [--port PORT] [--bind ADDR] [--tag TAG] [--name NAME] [--project PROJECT] [--no-pull]

Examples:
  ./start-linux.sh --configs-dir /opt/data/aiclient2api/configs --port 3009 --name aiclient2api-02
  ./start-linux.sh --configs-dir /opt/data/aiclient2api/configs --port 3009 --bind 127.0.0.1
  AICLIENT2API_TAG=latest HOST_PORT=3009 BIND_ADDR=127.0.0.1 CONFIGS_DIR=/opt/aiclient/configs ./start-linux.sh
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

CONFIGS_DIR="${CONFIGS_DIR:-$ROOT_DIR/configs}"
HOST_PORT="${HOST_PORT:-3009}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
AICLIENT2API_TAG="${AICLIENT2API_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-aiclient2api}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-aiclient-2-api}"
NO_PULL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configs-dir)
      CONFIGS_DIR="$2"; shift 2 ;;
    --port)
      HOST_PORT="$2"; shift 2 ;;
    --bind)
      BIND_ADDR="$2"; shift 2 ;;
    --tag)
      AICLIENT2API_TAG="$2"; shift 2 ;;
    --name)
      CONTAINER_NAME="$2"; shift 2 ;;
    --project)
      COMPOSE_PROJECT_NAME="$2"; shift 2 ;;
    --no-pull)
      NO_PULL=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# Docker Hub tags are like "2.2.12" (without the leading "v"). Accept either.
if [[ "$AICLIENT2API_TAG" =~ ^v[0-9] ]]; then
  AICLIENT2API_TAG="${AICLIENT2API_TAG#v}"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Please install Docker first." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin not found. Please install Docker Compose v2 (docker compose)." >&2
  exit 1
fi

mkdir -p "$CONFIGS_DIR"

created_api_key=""
created_admin_pwd=""

# Production-safe configs initialization (no example data, no hard-coded weak passwords).
if [[ ! -f "$CONFIGS_DIR/config.json" ]]; then
  created_api_key="$(gen_random_32)"
  cat >"$CONFIGS_DIR/config.json" <<EOF
{
  "REQUIRED_API_KEY": "${created_api_key}",
  "SERVER_PORT": 3000,
  "HOST": "0.0.0.0",
  "MODEL_PROVIDER": "gemini-cli-oauth",
  "PROMPT_LOG_MODE": "none",
  "CRON_REFRESH_TOKEN": false,
  "PROVIDER_POOLS_FILE_PATH": "configs/provider_pools.json",
  "MAX_ERROR_COUNT": 3,
  "providerFallbackChain": {}
}
EOF
  chmod 600 "$CONFIGS_DIR/config.json" || true
fi

if [[ ! -f "$CONFIGS_DIR/provider_pools.json" ]]; then
  echo '{}' >"$CONFIGS_DIR/provider_pools.json"
  chmod 600 "$CONFIGS_DIR/provider_pools.json" || true
fi

if [[ ! -f "$CONFIGS_DIR/pwd" ]]; then
  created_admin_pwd="$(gen_strong_password_32)"
  echo "${created_admin_pwd}" >"$CONFIGS_DIR/pwd"
  chmod 600 "$CONFIGS_DIR/pwd" || true
fi

export CONFIGS_DIR HOST_PORT BIND_ADDR AICLIENT2API_TAG CONTAINER_NAME COMPOSE_PROJECT_NAME

if [[ "$NO_PULL" -eq 0 ]]; then
  docker compose pull
fi

docker compose up -d --remove-orphans
docker compose ps

echo "Started in background. Port: ${HOST_PORT}  Configs: ${CONFIGS_DIR}  Image tag: ${AICLIENT2API_TAG}"

if [[ -n "${created_api_key}" ]]; then
  echo "Generated REQUIRED_API_KEY (saved to ${CONFIGS_DIR}/config.json): ${created_api_key}"
fi

if [[ -n "${created_admin_pwd}" ]]; then
  echo "Generated UI admin password (saved to ${CONFIGS_DIR}/pwd): ${created_admin_pwd}"
fi
