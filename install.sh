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
readonly DEFAULT_PORT=3001
readonly INSTALL_DIR="${HOME}/.digicode/compile-server"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly HEALTH_TIMEOUT_SEC=60
readonly DIGICODE_UI_PORT=3001  # the DigiCode UI's default — no extra step needed when PORT matches

# Resolved port for the running container — set by pick_port() during install
# or by read_port_from_compose() for subsequent commands.
PORT="${PORT:-}"

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
# Port handling
# ---------------------------------------------------------------------------

# Returns 0 if the port has no LISTEN-state TCP socket on localhost, 1 if it
# does. Tries lsof (best diagnostics, ships with macOS, common on Linux),
# then nc, and finally a pure-bash /dev/tcp probe so the script still works
# on minimal Linux images.
is_port_free() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    if nc -z localhost "$port" >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  # Bash builtin: try opening a TCP connection to localhost:port.
  if (exec 3<>/dev/tcp/localhost/"$port") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    return 1
  fi
  return 0
}

# Walk upward from $1 (default DEFAULT_PORT+1) until we find a free port,
# capped at +100 to avoid infinite loops on a fully booked machine.
find_next_free_port() {
  local start="${1:-$((DEFAULT_PORT + 1))}"
  local p
  for ((p = start; p < start + 100; p++)); do
    if is_port_free "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Best-effort: print "<pid> (<process>)" of whoever holds the LISTEN socket
# on $1, or empty string if we can't tell. Only lsof is guaranteed to give
# us this; other tools fall back to silence.
who_uses_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -i ":$port" -sTCP:LISTEN 2>/dev/null \
      | awk 'NR==2 {print $2 " (" $1 ")"}' \
      | head -1
  fi
}

# Decide which host port to expose. Always prompts the user (per
# 2026-05-01 user direction: "3001 が使用されていようがいまいがユーザーに認証求めた方がいい")
# unless PORT is set in the environment or stdin is not a TTY.
#
# Sets the PORT global; returns 0 on success, 1 on user abort or invalid env.
pick_port() {
  # Caller-supplied PORT (env var or --port flag) skips the prompt entirely.
  if [[ -n "${PORT:-}" ]]; then
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
      err "Invalid PORT='${PORT}' (must be an integer in 1024-65535)."
      return 1
    fi
    if ! is_port_free "$PORT"; then
      local owner; owner="$(who_uses_port "$PORT")"
      err "Port $PORT is already in use${owner:+ by $owner}."
      err "Pick a different port or stop the conflicting process."
      return 1
    fi
    info "Using port $PORT (set via environment)."
    return 0
  fi

  # No env override: probe DEFAULT_PORT and present the right prompt.
  local default
  if is_port_free "$DEFAULT_PORT"; then
    ok "Port ${DEFAULT_PORT} is available."
    default="$DEFAULT_PORT"
  else
    local owner; owner="$(who_uses_port "$DEFAULT_PORT")"
    warn "Port ${DEFAULT_PORT} is already in use${owner:+ by $owner}."
    warn "Binding the compile-server here would conflict with that process."
    info "Searching for the next free port…"
    if ! default="$(find_next_free_port $((DEFAULT_PORT + 1)))"; then
      err "No free port found in ${DEFAULT_PORT}-$((DEFAULT_PORT + 100)). Free a port and retry."
      return 1
    fi
    info "Suggested alternate: ${default}"
  fi

  # Non-TTY guard: `curl ... | bash` ties stdin to the curl pipe so `read`
  # would deadlock. Tell the user how to re-run interactively (or set PORT).
  if [[ ! -t 0 ]]; then
    err "Cannot prompt for the port: stdin is not a terminal."
    echo
    echo "  Re-run interactively (preferred):"
    echo "      bash <(curl -fsSL <installer-url>)"
    echo
    echo "  Or set PORT explicitly (skips the prompt):"
    echo "      PORT=${default} bash -c \"\$(curl -fsSL <installer-url>)\""
    echo
    return 1
  fi

  local prompt_msg="Enter port to use [${default}] (Enter to accept, 'q' to abort): "
  while true; do
    local reply
    read -r -p "$prompt_msg" reply
    case "$reply" in
      q|Q)
        info "Aborted by user."
        return 1
        ;;
      "")
        PORT="$default"
        return 0
        ;;
      *)
        if [[ ! "$reply" =~ ^[0-9]+$ ]] || (( reply < 1024 || reply > 65535 )); then
          err "Invalid port: must be an integer in 1024-65535. Try again."
          continue
        fi
        if ! is_port_free "$reply"; then
          local who; who="$(who_uses_port "$reply")"
          err "Port $reply is also in use${who:+ ($who)}. Try another."
          continue
        fi
        PORT="$reply"
        return 0
        ;;
    esac
  done
}

# Read the active host port from an existing docker-compose.yml. Used by
# the post-install subcommands (status / start / stop / update) so they
# don't have to know about pick_port.
read_port_from_compose() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    PORT="$DEFAULT_PORT"
    return 1
  fi
  local p
  # Match the first "  - "HOST:CONTAINER"" entry under ports:.
  p="$(grep -oE '^[[:space:]]*-[[:space:]]*"[0-9]+:[0-9]+"' "$COMPOSE_FILE" \
       | head -1 \
       | grep -oE '[0-9]+' \
       | head -1)"
  PORT="${p:-$DEFAULT_PORT}"
}

health_url() {
  echo "http://localhost:${PORT}/health"
}

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
# Host port: ${PORT} (chosen interactively, override with PORT env var or --port flag).
services:
  digicode-compile-api:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    ports:
      # The container listens on its built-in default (3001); we map it
      # to whatever host port the user picked.
      - "${PORT}:3001"
    restart: unless-stopped
    volumes:
      - digicode-projects:/opt/digicode-compile/projects
      - digicode-cache:/opt/digicode-compile/cache
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3001/health"]
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
  local url; url="$(health_url)"
  info "Waiting for compile-server to come up (timeout ${HEALTH_TIMEOUT_SEC}s)…"
  local end=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while (( $(date +%s) < end )); do
    if curl -fsS "$url" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "Compile-server is healthy at ${url}"
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

# Print the post-install summary. When the chosen port is not the
# DigiCode UI's default (3001), the user has to set the matching port in
# the frontend's "ローカルサーバー" port input — the installer reminds
# them with the exact value to type.
print_install_summary() {
  echo
  ok "${C_BOLD}DigiCode local compile-server is ready.${C_RESET}"
  echo
  echo "${C_BOLD}Next steps:${C_RESET}"
  echo "  1. Open DigiCode in your browser (https://code.fablab-westharima.jp)"
  echo "  2. Open ${C_BOLD}コンパイル設定${C_RESET} (Compile Settings)"
  echo "  3. Pick ${C_BOLD}ローカルサーバー${C_RESET} (Local Server)"
  if (( PORT == DIGICODE_UI_PORT )); then
    echo "     — the default port matches; nothing else to do."
  else
    echo "  4. ${C_BOLD}Set ポート番号 (Port) to ${PORT}${C_RESET}"
    echo "     so DigiCode talks to this server (the frontend persists this"
    echo "     in localStorage for next time)."
  fi
  echo
  echo "${C_DIM}Sanity check:${C_RESET}  curl http://localhost:${PORT}/health"
  echo
  echo "${C_DIM}Manage the server:${C_RESET}"
  echo "  • Status:    bash $0 status"
  echo "  • Stop:      bash $0 stop"
  echo "  • Update:    bash $0 update"
  echo "  • Uninstall: bash $0 uninstall"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_install() {
  require_docker
  require_docker_running

  if ! pick_port; then
    exit 1
  fi

  info "Writing compose file to ${COMPOSE_FILE} (host port ${PORT})"
  write_compose_file

  info "Pulling ${IMAGE} (≈1 GB compressed, ≈3.8 GB extracted on first run)…"
  docker_compose -f "$COMPOSE_FILE" pull

  info "Starting ${CONTAINER_NAME}…"
  docker_compose -f "$COMPOSE_FILE" up -d

  if ! wait_for_health; then
    exit 1
  fi

  print_install_summary
}

cmd_update() {
  require_docker
  require_docker_running
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found at ${COMPOSE_FILE}."
    echo "  Run 'bash $0 install' first."
    exit 1
  fi
  read_port_from_compose
  info "Pulling latest image…"
  docker_compose -f "$COMPOSE_FILE" pull
  info "Recreating container (host port ${PORT})…"
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

  read_port_from_compose

  local state image
  state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"

  local url; url="$(health_url)"
  echo "${C_BOLD}Container:${C_RESET}    ${CONTAINER_NAME}"
  echo "${C_BOLD}State:${C_RESET}        ${state}"
  echo "${C_BOLD}Image:${C_RESET}        ${image}"
  echo "${C_BOLD}Host port:${C_RESET}    ${PORT}"
  echo "${C_BOLD}Health URL:${C_RESET}   ${url}"
  echo "${C_BOLD}Compose:${C_RESET}      ${COMPOSE_FILE}"
  echo

  if [[ "$state" == "running" ]]; then
    if curl -fsS "$url" 2>/dev/null | grep -q '"status":"ok"'; then
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
  read_port_from_compose
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
  local current_port="${PORT:-$DEFAULT_PORT}"
  cat <<EOF
${C_BOLD}DigiCode local compile-server installer${C_RESET}

Usage: bash $0 [subcommand] [--port N]

Subcommands:
  install     Pull the image, ask which host port to use, generate the
              compose file, start the container, verify /health
              (default if no subcommand given)
  update      Pull the latest image and recreate the container,
              keeping the same port and volumes as the previous install
  uninstall   Stop the container, remove volumes and install dir
              (asks before deleting the image)
  status      Show container state, image, host port, and a live health check
  start       Start an existing (stopped) container
  stop        Stop the container without removing it
  help        Show this message

Port selection:
  • install always asks which host port to use, with a smart default
    (${DEFAULT_PORT} if free, or the next free port if ${DEFAULT_PORT} is taken).
  • Pass --port N or set PORT=N to skip the prompt
    (useful when piping curl | bash where stdin is not interactive).
  • update / status / start / stop read the active port from the
    generated compose file, so they stay in sync automatically.

Install dir:    ${INSTALL_DIR}
Image:          ${IMAGE}
Default port:   ${DEFAULT_PORT}  (also DigiCode UI's default; UI accepts custom ports)
Health URL:     http://localhost:${current_port}/health

Docs (5 langs): https://code.fablab-westharima.jp/docs/local-compile-server
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Parse `--port N` out of $@, leaving the first non-flag argument as the
# subcommand. The flag may appear before or after the subcommand. PORT env
# var still wins; the flag is just sugar for one-off interactive runs.
#
# We resolve the subcommand into a single scalar (PARSED_SUB) instead of
# building an array. macOS ships Bash 3.2, where `set -u` plus expanding an
# empty array (`"${rest[@]}"`) raises "unbound variable" — hitting users
# who curl-pipe into the system bash with no arguments. A scalar avoids
# the entire empty-array minefield.
parse_port_flag() {
  PARSED_SUB=""
  while (( $# > 0 )); do
    case "$1" in
      --port)
        if [[ -z "${2:-}" ]]; then
          err "--port requires an argument"
          exit 1
        fi
        PORT="$2"
        shift 2
        ;;
      --port=*)
        PORT="${1#--port=}"
        shift
        ;;
      *)
        # First non-flag positional wins as the subcommand. Any extras
        # are silently ignored (we never accept multi-positional args).
        if [[ -z "$PARSED_SUB" ]]; then
          PARSED_SUB="$1"
        fi
        shift
        ;;
    esac
  done
}

main() {
  PARSED_SUB=""
  parse_port_flag "$@"
  local sub="${PARSED_SUB:-install}"
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
