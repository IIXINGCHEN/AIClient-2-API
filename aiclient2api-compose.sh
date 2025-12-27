#!/usr/bin/env bash
# Generate production docker-compose.yml + minimal configs for AIClient-2-API (official image).

set -euo pipefail

# Ensure secrets we create are not world-readable.
umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  ./aiclient2api-compose.sh [options]

Options:
  --bind ADDR        Host bind address for port mapping (default: 127.0.0.1)
  --port PORT        Host port to publish (default: 3009)
  --tag TAG          Image tag (default: latest). Accepts v-prefixed tags too.
  --name NAME        Container name (default: aiclient2api)
  --configs-dir DIR  Host configs directory to mount to /app/configs (default: ./configs)
  --overwrite        Overwrite existing docker-compose.yml
  --no-pull          Do not pull image
  --up               Start in background after generating (docker compose up -d)
  -h, --help         Show help

Examples:
  ./aiclient2api-compose.sh --configs-dir /opt/data/api/AIClient-2-API-02/configs --port 3009 --bind 127.0.0.1 --name aiclient2api-02 --up
EOF
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

run_pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    if is_root; then
      apt-get update && apt-get install -y "${pkgs[@]}"
    else
      sudo apt-get update && sudo apt-get install -y "${pkgs[@]}"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if is_root; then
      dnf install -y "${pkgs[@]}"
    else
      sudo dnf install -y "${pkgs[@]}"
    fi
  elif command -v yum >/dev/null 2>&1; then
    if is_root; then
      yum install -y "${pkgs[@]}"
    else
      sudo yum install -y "${pkgs[@]}"
    fi
  elif command -v zypper >/dev/null 2>&1; then
    if is_root; then
      zypper install -y "${pkgs[@]}"
    else
      sudo zypper install -y "${pkgs[@]}"
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if is_root; then
      pacman -S --noconfirm "${pkgs[@]}"
    else
      sudo pacman -S --noconfirm "${pkgs[@]}"
    fi
  else
    return 1
  fi
}

check_deps() {
  info "Checking dependencies..."
  if ! command -v docker >/dev/null 2>&1; then
    err "docker not found. Install Docker first."
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose plugin not found. Install Docker Compose v2 (docker compose)."
    exit 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found; trying to install..."
    if ! command -v sudo >/dev/null 2>&1 && ! is_root; then
      err "Need sudo (or run as root) to install openssl automatically."
      exit 1
    fi
    if ! run_pkg_install openssl ca-certificates; then
      err "Cannot auto-install openssl; please install it and re-run."
      exit 1
    fi
  fi
  ok "Dependencies OK"
}

gen_random() {
  local s=""
  if command -v openssl >/dev/null 2>&1; then
    s=$(openssl rand -base64 48 2>/dev/null | tr -d '=+/\n ' | cut -c1-32 || true)
  fi
  if [[ -z "$s" && -r /dev/urandom ]]; then
    s=$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n ' | cut -c1-32 || true)
  fi
  if [[ -z "$s" ]]; then
    s=$(for _ in $(seq 1 32); do printf "%X" $((RANDOM % 16)); done)
  fi
  while [[ ${#s} -lt 32 ]]; do
    s+=$(printf "%X" $((RANDOM % 16)))
  done
  echo "${s:0:32}"
}

gen_sk_api_key() {
  local base=""
  if command -v openssl >/dev/null 2>&1; then
    base=$(openssl rand -base64 96 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 48 || true)
  fi
  if [[ -z "$base" && -r /dev/urandom ]]; then
    base=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 48 || true)
  fi
  while [[ ${#base} -lt 48 ]]; do
    base+="$(gen_random)"
    base=$(echo -n "$base" | tr -dc 'A-Za-z0-9')
    base="${base:0:48}"
  done
  echo "sk-${base:0:48}"
}

gen_strong_password_32() {
  local base=""
  if [[ -r /dev/urandom ]]; then
    base=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 28 || true)
  fi
  if [[ ${#base} -lt 28 ]]; then
    base=$(gen_random | cut -c1-28)
  fi
  echo "${base}Aa0B" | cut -c1-32
}

main() {
  local bind_addr="127.0.0.1"
  local host_port="3009"
  local tag="latest"
  local container_name="aiclient2api"
  local configs_dir="./configs"
  local overwrite=0
  local no_pull=0
  local do_up=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bind) bind_addr="$2"; shift 2 ;;
      --port) host_port="$2"; shift 2 ;;
      --tag) tag="$2"; shift 2 ;;
      --name) container_name="$2"; shift 2 ;;
      --configs-dir) configs_dir="$2"; shift 2 ;;
      --overwrite) overwrite=1; shift ;;
      --no-pull) no_pull=1; shift ;;
      --up) do_up=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
  done

  # Normalize tag: Docker Hub tags are like "2.2.12" (without leading "v").
  if [[ "$tag" =~ ^v[0-9] ]]; then
    tag="${tag#v}"
  fi

  check_deps

  if [[ -f docker-compose.yml && "$overwrite" -ne 1 ]]; then
    warn "docker-compose.yml already exists. Overwriting it will change published ports/name settings."
    echo -n "Overwrite docker-compose.yml? (y/N): "
    read -r choice
    case "$choice" in
      y|Y|yes|YES|Yes) overwrite=1 ;;
      *) info "Cancelled."; exit 0 ;;
    esac
  fi

  mkdir -p "$configs_dir"

  local api_key=""

  # Seed minimal config files if absent (do not overwrite existing).
  if [[ ! -f "$configs_dir/config.json" ]]; then
    info "Generating API key (REQUIRED_API_KEY, sk-*)..."
    api_key="$(gen_sk_api_key)"
    if [[ -z "$api_key" ]]; then
      err "Failed to generate API key."
      exit 1
    fi

    cat >"$configs_dir/config.json" <<EOF
{
  "REQUIRED_API_KEY": "${api_key}",
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
    ok "Created ${configs_dir%/}/config.json"
    chmod 600 "$configs_dir/config.json" || true
  else
    warn "Keeping existing ${configs_dir%/}/config.json (not overwriting)."
  fi

  if [[ ! -f "$configs_dir/provider_pools.json" ]]; then
    echo '{}' >"$configs_dir/provider_pools.json"
    ok "Created ${configs_dir%/}/provider_pools.json"
    chmod 600 "$configs_dir/provider_pools.json" || true
  fi

  if [[ ! -f "$configs_dir/pwd" ]]; then
    local admin_pwd
    admin_pwd="$(gen_strong_password_32)"
    echo "${admin_pwd}" >"$configs_dir/pwd"
    chmod 600 "$configs_dir/pwd" || true
    ok "Created ${configs_dir%/}/pwd (strong password generated)"
    echo "UI admin password (saved to ${configs_dir%/}/pwd): ${admin_pwd}"
  fi

  info "Generating docker-compose.yml..."
  cat > docker-compose.yml <<EOF
services:
  aiclient2api:
    image: "justlikemaki/aiclient-2-api:${tag}"
    container_name: "${container_name}"
    restart: always
    init: true
    ports:
      - "${bind_addr}:${host_port}:3000"
    volumes:
      - "${configs_dir}:/app/configs"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

  ok "docker-compose.yml generated"

  echo
  if [[ -n "$api_key" ]]; then
    echo "API KEY (REQUIRED_API_KEY): ${api_key}"
  else
    echo "API KEY (REQUIRED_API_KEY): unchanged (see ${configs_dir%/}/config.json)"
  fi
  echo "Bind: ${bind_addr}:${host_port} -> container:3000"
  echo "Configs dir: ${configs_dir}"
  echo "Image: justlikemaki/aiclient-2-api:${tag}"

  if [[ "$no_pull" -eq 0 ]]; then
    info "Pulling image..."
    docker compose pull
  fi

  if [[ "$do_up" -eq 1 ]]; then
    info "Starting in background..."
    docker compose up -d --remove-orphans
    docker compose ps
  else
    echo
    echo "Next:"
    echo "  docker compose up -d"
    echo "  curl -s http://${bind_addr}:${host_port}/health"
  fi
}

trap 'err "Script failed at line $LINENO"' ERR
main "$@"
