#!/usr/bin/env bash
# DigiCode local compile-server installer (Mac / Linux).
# https://github.com/fablab-westharima/digicode-installer
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.sh | bash
#
# Subcommands:
#   install (default), update, uninstall, status, start, stop, help
#
# Pulls ghcr.io/fablab-westharima/digicode-compile-api:latest, starts it on
# port 3001 with persistent named volumes, then prints the next steps.
# Docker must be installed beforehand; the script aborts with an OS-specific
# download URL if it is missing.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly IMAGE="ghcr.io/fablab-westharima/digicode-compile-api:latest"
readonly CONTAINER_NAME="digicode-compile-api"
readonly PORT=3001
readonly INSTALL_DIR="${HOME}/.digicode/compile-server"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly HEALTH_URL="http://localhost:${PORT}/health"
readonly HEALTH_TIMEOUT_SEC=60

# ANSI colours (disabled when not a tty)
if [[ -t 1 ]]; then
  readonly C_BOLD=$'\033[1m'
  readonly C_DIM=$'\033[2m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_BOLD=""
  readonly C_DIM=""
  readonly C_RED=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_BLUE=""
  readonly C_RESET=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info() { printf "%s▶%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%s✅%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s⚠️ %s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s❌%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

detect_os() {
  local kernel
  kernel="$(uname -s)"
  case "$kernel" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

detect_mac_arch() {
  case "$(uname -m)" in
    arm64) echo "apple-silicon" ;;
    x86_64) echo "intel" ;;
    *) echo "unknown" ;;
  esac
}

detect_linux_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# Docker / Compose preflight
# ---------------------------------------------------------------------------

require_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi

  err "Docker not found in PATH."
  echo
  echo "${C_BOLD}DigiCode local compile-server requires Docker.${C_RESET}"
  echo "Please install Docker for your platform and re-run this script:"
  echo

  local os
  os="$(detect_os)"
  case "$os" in
    macos)
      local arch
      arch="$(detect_mac_arch)"
      if [[ "$arch" == "apple-silicon" ]]; then
        echo "  • ${C_BOLD}OrbStack${C_RESET} (recommended, lightweight, Apple Silicon native)"
        echo "      https://orbstack.dev/"
        echo "  • ${C_BOLD}Docker Desktop for Mac (Apple Silicon)${C_RESET}"
        echo "      https://www.docker.com/products/docker-desktop/"
      else
        echo "  • ${C_BOLD}Docker Desktop for Mac (Intel)${C_RESET}"
        echo "      https://www.docker.com/products/docker-desktop/"
      fi
      ;;
    linux)
      local distro
      distro="$(detect_linux_distro)"
      case "$distro" in
        ubuntu|debian)
          echo "  ${C_BOLD}Ubuntu / Debian:${C_RESET}"
          echo "    sudo apt update && sudo apt install -y docker.io docker-compose-plugin"
          echo "    sudo systemctl enable --now docker"
          echo "    sudo usermod -aG docker \$USER"
          echo "    # then log out and back in"
          ;;
        fedora|rhel|centos|rocky|almalinux)
          echo "  ${C_BOLD}Fedora / RHEL / CentOS:${C_RESET}"
          echo "    sudo dnf install -y docker docker-compose-plugin"
          echo "    sudo systemctl enable --now docker"
          echo "    sudo usermod -aG docker \$USER"
          ;;
        arch|manjaro)
          echo "  ${C_BOLD}Arch / Manjaro:${C_RESET}"
          echo "    sudo pacman -S --needed docker docker-compose"
          echo "    sudo systemctl enable --now docker"
          echo "    sudo usermod -aG docker \$USER"
          ;;
        *)
          echo "  Linux (generic): https://docs.docker.com/engine/install/"
          ;;
      esac
      ;;
    *)
      echo "  https://www.docker.com/products/docker-desktop/"
      ;;
  esac
  echo
  exit 1
}

require_docker_running() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  err "Docker is installed but not running."
  echo
  case "$(detect_os)" in
    macos) echo "Start Docker Desktop (or OrbStack) from Applications, then re-run." ;;
    linux) echo "Start the Docker daemon: sudo systemctl start docker" ;;
  esac
  echo
  exit 1
}

# `docker compose` (plugin) vs the legacy `docker-compose` binary. We prefer
# the plugin, which is what every modern Docker install ships.
docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available."
    echo "Install the Docker Compose plugin (bundled with recent Docker)."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# docker-compose.yml generation
# ---------------------------------------------------------------------------

write_compose_file() {
  mkdir -p "$INSTALL_DIR"
  cat > "$COMPOSE_FILE" <<EOF
# Generated by DigiCode local-compile installer.
# Edit at your own risk — re-running 'install' overwrites this file.
services:
  digicode-compile-api:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    ports:
      - "${PORT}:${PORT}"
    restart: unless-stopped
    environment:
      - PORT=${PORT}
    volumes:
      - digicode-projects:/opt/digicode-compile/projects
      - digicode-cache:/opt/digicode-compile/cache
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:${PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  digicode-projects:
  digicode-cache:
EOF
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

wait_for_health() {
  info "Waiting for compile-server to come up (timeout ${HEALTH_TIMEOUT_SEC}s)…"
  local end=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while (( $(date +%s) < end )); do
    if curl -fsS "$HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "Compile-server is healthy at ${HEALTH_URL}"
      return 0
    fi
    sleep 2
    printf "."
  done
  printf "\n"
  err "Health check timed out after ${HEALTH_TIMEOUT_SEC}s."
  echo "  Inspect logs with:  docker logs ${CONTAINER_NAME}"
  return 1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_install() {
  require_docker
  require_docker_running

  info "Writing compose file to ${COMPOSE_FILE}"
  write_compose_file

  info "Pulling ${IMAGE} (≈1 GB compressed, ≈3.8 GB extracted on first run)…"
  docker_compose -f "$COMPOSE_FILE" pull

  info "Starting ${CONTAINER_NAME}…"
  docker_compose -f "$COMPOSE_FILE" up -d

  if ! wait_for_health; then
    exit 1
  fi

  echo
  ok "${C_BOLD}DigiCode local compile-server is ready.${C_RESET}"
  echo
  echo "${C_BOLD}Next steps:${C_RESET}"
  echo "  1. Open DigiCode in your browser (https://code.fablab-westharima.jp)"
  echo "  2. Click the ▼ next to the「書き込み」button"
  echo "  3. Select「ローカルサーバー」"
  echo
  echo "${C_DIM}Manage the server:${C_RESET}"
  echo "  • Status:    bash $0 status"
  echo "  • Stop:      bash $0 stop"
  echo "  • Update:    bash $0 update"
  echo "  • Uninstall: bash $0 uninstall"
}

cmd_update() {
  require_docker
  require_docker_running
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found at ${COMPOSE_FILE}."
    echo "  Run 'bash $0 install' first."
    exit 1
  fi
  info "Pulling latest image…"
  docker_compose -f "$COMPOSE_FILE" pull
  info "Recreating container…"
  docker_compose -f "$COMPOSE_FILE" up -d
  wait_for_health
}

cmd_uninstall() {
  require_docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    warn "Compose file not found at ${COMPOSE_FILE} — nothing to uninstall."
    return 0
  fi

  echo "${C_BOLD}This will:${C_RESET}"
  echo "  • Stop and remove the ${CONTAINER_NAME} container"
  echo "  • Delete the persistent volumes (digicode-projects, digicode-cache)"
  echo "  • Delete ${INSTALL_DIR}"
  echo
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; return 0 ;;
  esac

  info "Stopping container and removing volumes…"
  docker_compose -f "$COMPOSE_FILE" down -v || true

  info "Removing ${INSTALL_DIR}…"
  rm -rf "$INSTALL_DIR"

  echo
  read -r -p "Also delete the Docker image (${IMAGE})? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      info "Removing image…"
      docker rmi "$IMAGE" 2>/dev/null || warn "Image not found (already removed?)"
      ;;
    *) ;;
  esac

  ok "Uninstall complete."
}

cmd_status() {
  require_docker
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "${CONTAINER_NAME} is not installed."
    echo "  Run 'bash $0 install' to set it up."
    return 1
  fi

  local state image
  state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"

  echo "${C_BOLD}Container:${C_RESET}    ${CONTAINER_NAME}"
  echo "${C_BOLD}State:${C_RESET}        ${state}"
  echo "${C_BOLD}Image:${C_RESET}        ${image}"
  echo "${C_BOLD}Health URL:${C_RESET}   ${HEALTH_URL}"
  echo "${C_BOLD}Compose:${C_RESET}      ${COMPOSE_FILE}"
  echo

  if [[ "$state" == "running" ]]; then
    if curl -fsS "$HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "Health check passed."
    else
      warn "Container is running but /health is not responding (still starting?)."
    fi
  fi
}

cmd_start() {
  require_docker
  require_docker_running
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found — run 'install' first."
    exit 1
  fi
  docker_compose -f "$COMPOSE_FILE" start
  wait_for_health
}

cmd_stop() {
  require_docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found — run 'install' first."
    exit 1
  fi
  docker_compose -f "$COMPOSE_FILE" stop
  ok "Stopped."
}

cmd_help() {
  cat <<EOF
${C_BOLD}DigiCode local compile-server installer${C_RESET}

Usage: bash $0 [subcommand]

Subcommands:
  install     Pull the image, generate compose file, start the container,
              then verify /health (default if no subcommand given)
  update      Pull the latest image and recreate the container
  uninstall   Stop the container, remove volumes and install dir
              (asks before deleting the image)
  status      Show container state, image, and a live health check
  start       Start an existing (stopped) container
  stop        Stop the container without removing it
  help        Show this message

Install dir:    ${INSTALL_DIR}
Image:          ${IMAGE}
Health URL:     ${HEALTH_URL}

Docs (5 langs): https://code.fablab-westharima.jp/docs/local-compile-server
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local sub="${1:-install}"
  case "$sub" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    help|-h|--help) cmd_help ;;
    *)
      err "Unknown subcommand: $sub"
      echo
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
