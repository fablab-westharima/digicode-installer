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
#
# Localization (Tier 1: ja + en):
#   - macOS: detected from $LANG (ja_*  -> ja; everything else -> en).
#   - Linux: forced to en regardless of $LANG, because terminal locale support
#     varies wildly across distros / SSH / minimal images and we don't want
#     to spray "????" into the user's terminal.
#   - Override either by exporting DIGICODE_LANG=ja or DIGICODE_LANG=en.

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
# Localization
# ---------------------------------------------------------------------------
# LANG_CODE = "ja" or "en". Linux is pinned to en. DIGICODE_LANG always wins.

LANG_CODE="en"

detect_lang() {
  if [[ -n "${DIGICODE_LANG:-}" ]]; then
    case "$DIGICODE_LANG" in
      ja|ja_*|ja-*) LANG_CODE="ja" ;;
      *)            LANG_CODE="en" ;;
    esac
    return
  fi
  if [[ "$(uname -s)" == "Linux" ]]; then
    LANG_CODE="en"
    return
  fi
  case "${LANG:-}" in
    ja*) LANG_CODE="ja" ;;
    *)   LANG_CODE="en" ;;
  esac
}

# t key [args...] — print the localized message for `key`, with printf-style
# %s substitution for any extra args. Falls back to en if a key is missing
# in ja (defensive — shouldn't happen, but better than printing the literal
# key name).
t() {
  local key="$1"; shift || true
  local fmt=""
  if [[ "$LANG_CODE" == "ja" ]]; then
    fmt="$(_msg_ja "$key")"
  fi
  if [[ -z "$fmt" ]]; then
    fmt="$(_msg_en "$key")"
  fi
  if [[ "$#" -gt 0 ]]; then
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
  else
    printf "%s" "$fmt"
  fi
}

# English catalog. Every key the script uses must have a row here.
_msg_en() {
  case "$1" in
    docker_not_found)            echo "Docker not found in PATH." ;;
    docker_required)             echo "DigiCode local compile-server requires Docker." ;;
    docker_install_prompt)       echo "Please install Docker for your platform and re-run this script:" ;;
    docker_orbstack)             echo "OrbStack (recommended, lightweight, Apple Silicon native)" ;;
    docker_desktop_apple)        echo "Docker Desktop for Mac (Apple Silicon)" ;;
    docker_desktop_intel)        echo "Docker Desktop for Mac (Intel)" ;;
    docker_linux_generic)        echo "Linux (generic): https://docs.docker.com/engine/install/" ;;
    docker_logout_back_in)       echo "# then log out and back in" ;;
    docker_not_running)          echo "Docker is installed but not running." ;;
    docker_start_macos)          echo "Start Docker Desktop (or OrbStack) from Applications, then re-run." ;;
    docker_start_linux)          echo "Start the Docker daemon: sudo systemctl start docker" ;;
    docker_compose_missing)      echo "Neither 'docker compose' nor 'docker-compose' is available." ;;
    docker_compose_install_hint) echo "Install the Docker Compose plugin (bundled with recent Docker)." ;;

    port_invalid_env)            echo "Invalid PORT='%s' (must be an integer in 1024-65535)." ;;
    port_in_use_env)             echo "Port %s is already in use%s." ;;
    port_pick_different)         echo "Pick a different port or stop the conflicting process." ;;
    port_using_env)              echo "Using port %s (set via environment)." ;;
    port_default_free)           echo "Port %s is available." ;;
    port_default_in_use_warn)    echo "Port %s is already in use%s." ;;
    port_bind_conflict_warn)     echo "Binding the compile-server here would conflict with that process." ;;
    port_search_next)            echo "Searching for the next free port…" ;;
    port_no_free_in_range)       echo "No free port found in %s-%s. Free a port and retry." ;;
    port_suggested_alt)          echo "Suggested alternate: %s" ;;
    port_stdin_not_tty)          echo "Cannot prompt for the port: stdin is not a terminal." ;;
    port_rerun_interactively)    echo "Re-run interactively (preferred):" ;;
    port_or_set_explicitly)      echo "Or set PORT explicitly (skips the prompt):" ;;
    port_prompt)                 echo "Enter port to use [%s] (Enter to accept, 'q' to abort): " ;;
    port_aborted)                echo "Aborted by user." ;;
    port_invalid_retry)          echo "Invalid port: must be an integer in 1024-65535. Try again." ;;
    port_also_in_use)            echo "Port %s is also in use%s. Try another." ;;
    port_owner_suffix)           echo " by %s" ;;
    port_owner_suffix_paren)     echo " (%s)" ;;

    health_waiting)              echo "Waiting for compile-server to come up (timeout %ss)…" ;;
    health_ok)                   echo "Compile-server is healthy at %s" ;;
    health_timeout)              echo "Health check timed out after %ss." ;;
    health_inspect_logs)         echo "Inspect logs with:  docker logs %s" ;;

    summary_title)               echo "DigiCode local compile-server is ready." ;;
    summary_next_steps)          echo "Next steps:" ;;
    summary_step1)               echo "1. Open DigiCode in your browser (https://code.fablab-westharima.jp)" ;;
    summary_step2)               echo "2. Open Compile Settings (コンパイル設定)" ;;
    summary_step3)               echo "3. Pick Local Server (ローカルサーバー)" ;;
    summary_default_match)       echo "— the default port matches; nothing else to do." ;;
    summary_step4)               echo "4. Set Port (ポート番号) to %s" ;;
    summary_step4_hint)          echo "so DigiCode talks to this server (the frontend persists this in localStorage for next time)." ;;
    summary_sanity)              echo "Sanity check:" ;;
    summary_manage)              echo "Manage the server:" ;;
    summary_status_label)        echo "Status:" ;;
    summary_stop_label)          echo "Stop:" ;;
    summary_update_label)        echo "Update:" ;;
    summary_uninstall_label)     echo "Uninstall:" ;;

    install_writing_compose)     echo "Writing compose file to %s (host port %s)" ;;
    install_pulling_image)       echo "Pulling %s (~2.1 GB compressed, ~8.8 GB extracted on first run)…" ;;
    install_starting_container)  echo "Starting %s…" ;;

    update_compose_missing)      echo "Compose file not found at %s." ;;
    update_run_install_first)    echo "Run 'bash %s install' first." ;;
    update_pulling_latest)       echo "Pulling latest image…" ;;
    update_recreating)           echo "Recreating container (host port %s)…" ;;

    uninstall_compose_missing)   echo "Compose file not found at %s — nothing to uninstall." ;;
    uninstall_will_title)        echo "This will:" ;;
    uninstall_will_stop)         echo "Stop and remove the %s container" ;;
    uninstall_will_volumes)      echo "Delete the persistent volumes (digicode-projects, digicode-cache)" ;;
    uninstall_will_dir)          echo "Delete %s" ;;
    uninstall_continue_prompt)   echo "Continue? [y/N] " ;;
    uninstall_cancelled)         echo "Cancelled." ;;
    uninstall_stopping)          echo "Stopping container and removing volumes…" ;;
    uninstall_removing_dir)      echo "Removing %s…" ;;
    uninstall_image_prompt)      echo "Also delete the Docker image (%s)? [y/N] " ;;
    uninstall_removing_image)    echo "Removing image…" ;;
    uninstall_image_not_found)   echo "Image not found (already removed?)" ;;
    uninstall_complete)          echo "Uninstall complete." ;;

    status_not_installed)        echo "%s is not installed." ;;
    status_run_install)          echo "Run 'bash %s install' to set it up." ;;
    status_container_label)      echo "Container:" ;;
    status_state_label)          echo "State:" ;;
    status_image_label)          echo "Image:" ;;
    status_host_port_label)      echo "Host port:" ;;
    status_health_url_label)     echo "Health URL:" ;;
    status_compose_label)        echo "Compose:" ;;
    status_health_passed)        echo "Health check passed." ;;
    status_health_not_responding) echo "Container is running but /health is not responding (still starting?)." ;;

    start_compose_missing)       echo "Compose file not found — run 'install' first." ;;
    stop_complete)               echo "Stopped." ;;

    port_flag_arg_required)      echo "--port requires an argument" ;;
    unknown_subcommand)          echo "Unknown subcommand: %s" ;;
    *) echo "" ;;
  esac
}

# Japanese catalog. Same keys, translated. Use ASCII spaces around %s so
# printf works the same as the en catalog. Punctuation uses 全角 only when
# it's at the end of a sentence or between Japanese-only spans; mixed
# Japanese / Latin / numbers stays half-width to avoid awkward spacing.
_msg_ja() {
  case "$1" in
    docker_not_found)            echo "Docker が PATH 上に見つかりません。" ;;
    docker_required)             echo "DigiCode のローカルコンパイルサーバーには Docker が必要です。" ;;
    docker_install_prompt)       echo "下記から Docker をインストールしてからこのスクリプトを再実行してください:" ;;
    docker_orbstack)             echo "OrbStack (推奨。軽量で Apple Silicon にネイティブ対応)" ;;
    docker_desktop_apple)        echo "Docker Desktop for Mac (Apple Silicon 版)" ;;
    docker_desktop_intel)        echo "Docker Desktop for Mac (Intel 版)" ;;
    docker_linux_generic)        echo "Linux (汎用): https://docs.docker.com/engine/install/" ;;
    docker_logout_back_in)       echo "# 反映するには一度ログアウトして再ログインしてください" ;;
    docker_not_running)          echo "Docker はインストール済みですが起動していません。" ;;
    docker_start_macos)          echo "Applications から Docker Desktop (または OrbStack) を起動してから再実行してください。" ;;
    docker_start_linux)          echo "Docker daemon を起動してください: sudo systemctl start docker" ;;
    docker_compose_missing)      echo "'docker compose' も 'docker-compose' も見つかりません。" ;;
    docker_compose_install_hint) echo "Docker Compose プラグインをインストールしてください (最近の Docker には同梱されています)。" ;;

    port_invalid_env)            echo "PORT='%s' は不正です (1024〜65535 の整数で指定してください)。" ;;
    port_in_use_env)             echo "ポート %s は既に使用されています%s。" ;;
    port_pick_different)         echo "別のポートを指定するか、競合しているプロセスを停止してください。" ;;
    port_using_env)              echo "ポート %s を使用します (環境変数で指定)。" ;;
    port_default_free)           echo "ポート %s は利用可能です。" ;;
    port_default_in_use_warn)    echo "ポート %s は既に使用されています%s。" ;;
    port_bind_conflict_warn)     echo "このポートでコンパイルサーバーを起動すると上記プロセスと競合します。" ;;
    port_search_next)            echo "別の空きポートを検索しています…" ;;
    port_no_free_in_range)       echo "%s〜%s の範囲に空きポートがありません。ポートを解放してから再実行してください。" ;;
    port_suggested_alt)          echo "代替候補: %s" ;;
    port_stdin_not_tty)          echo "ポートを問い合わせできません: stdin が端末ではありません。" ;;
    port_rerun_interactively)    echo "対話モードで再実行してください (推奨):" ;;
    port_or_set_explicitly)      echo "あるいは PORT を明示的に指定 (プロンプトをスキップ):" ;;
    port_prompt)                 echo "使用するポートを入力 [%s] (Enter で確定、'q' で中止): " ;;
    port_aborted)                echo "ユーザー操作により中止しました。" ;;
    port_invalid_retry)          echo "不正なポートです: 1024〜65535 の整数を入力してください。" ;;
    port_also_in_use)            echo "ポート %s も使用中です%s。別のポートを指定してください。" ;;
    port_owner_suffix)           echo " (%s が使用中)" ;;
    port_owner_suffix_paren)     echo " (%s)" ;;

    health_waiting)              echo "コンパイルサーバーの起動を待機中です (タイムアウト %s 秒)…" ;;
    health_ok)                   echo "コンパイルサーバーは正常に稼働しています: %s" ;;
    health_timeout)              echo "ヘルスチェックが %s 秒でタイムアウトしました。" ;;
    health_inspect_logs)         echo "ログを確認:  docker logs %s" ;;

    summary_title)               echo "DigiCode のローカルコンパイルサーバーが準備完了しました。" ;;
    summary_next_steps)          echo "次のステップ:" ;;
    summary_step1)               echo "1. ブラウザで DigiCode を開く (https://code.fablab-westharima.jp)" ;;
    summary_step2)               echo "2. 「コンパイル設定」を開く" ;;
    summary_step3)               echo "3. 「ローカルサーバー」を選択" ;;
    summary_default_match)       echo "— デフォルトポートと一致するため、追加設定は不要。" ;;
    summary_step4)               echo "4. 「ポート番号」を %s に設定" ;;
    summary_step4_hint)          echo "DigiCode が本サーバーと通信できるようになります (ブラウザの localStorage に保存され、次回からは不要)。" ;;
    summary_sanity)              echo "動作確認:" ;;
    summary_manage)              echo "サーバー管理:" ;;
    summary_status_label)        echo "状態確認:" ;;
    summary_stop_label)          echo "停止:" ;;
    summary_update_label)        echo "更新:" ;;
    summary_uninstall_label)     echo "アンインストール:" ;;

    install_writing_compose)     echo "compose ファイルを %s に書き出し中 (ホストポート %s)" ;;
    install_pulling_image)       echo "%s をダウンロード中 (圧縮 ~2.1 GB / 展開後 ~8.8 GB、初回のみ)…" ;;
    install_starting_container)  echo "%s を起動中…" ;;

    update_compose_missing)      echo "compose ファイルが見つかりません: %s" ;;
    update_run_install_first)    echo "先に 'bash %s install' を実行してください。" ;;
    update_pulling_latest)       echo "最新イメージをダウンロード中…" ;;
    update_recreating)           echo "コンテナを再作成中 (ホストポート %s)…" ;;

    uninstall_compose_missing)   echo "compose ファイルが見つかりません (%s) — アンインストール対象がありません。" ;;
    uninstall_will_title)        echo "以下を実行します:" ;;
    uninstall_will_stop)         echo "%s コンテナを停止して削除" ;;
    uninstall_will_volumes)      echo "永続ボリューム (digicode-projects、digicode-cache) を削除" ;;
    uninstall_will_dir)          echo "%s を削除" ;;
    uninstall_continue_prompt)   echo "続行しますか? [y/N] " ;;
    uninstall_cancelled)         echo "キャンセルしました。" ;;
    uninstall_stopping)          echo "コンテナを停止しボリュームを削除中…" ;;
    uninstall_removing_dir)      echo "%s を削除中…" ;;
    uninstall_image_prompt)      echo "Docker イメージ (%s) も削除しますか? [y/N] " ;;
    uninstall_removing_image)    echo "イメージを削除中…" ;;
    uninstall_image_not_found)   echo "イメージが見つかりません (既に削除済みの可能性)" ;;
    uninstall_complete)          echo "アンインストールが完了しました。" ;;

    status_not_installed)        echo "%s はインストールされていません。" ;;
    status_run_install)          echo "セットアップするには 'bash %s install' を実行してください。" ;;
    status_container_label)      echo "コンテナ:" ;;
    status_state_label)          echo "状態:" ;;
    status_image_label)          echo "イメージ:" ;;
    status_host_port_label)      echo "ホストポート:" ;;
    status_health_url_label)     echo "ヘルス URL:" ;;
    status_compose_label)        echo "Compose:" ;;
    status_health_passed)        echo "ヘルスチェック OK。" ;;
    status_health_not_responding) echo "コンテナは起動中ですが /health が応答しません (起動処理中の可能性)。" ;;

    start_compose_missing)       echo "compose ファイルが見つかりません — 先に 'install' を実行してください。" ;;
    stop_complete)               echo "停止しました。" ;;

    port_flag_arg_required)      echo "--port には引数が必要です" ;;
    unknown_subcommand)          echo "不明なサブコマンドです: %s" ;;
    *) echo "" ;;
  esac
}

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

# Wrap an owner string ("pid (proc)") into the "by ..." or " (...)" suffix
# in the active language. Empty input -> empty output.
fmt_owner_suffix() {
  local owner="$1"
  [[ -z "$owner" ]] && return 0
  t port_owner_suffix "$owner"
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
      err "$(t port_invalid_env "$PORT")"
      return 1
    fi
    if ! is_port_free "$PORT"; then
      local owner; owner="$(who_uses_port "$PORT")"
      err "$(t port_in_use_env "$PORT" "$(fmt_owner_suffix "$owner")")"
      err "$(t port_pick_different)"
      return 1
    fi
    info "$(t port_using_env "$PORT")"
    return 0
  fi

  # No env override: probe DEFAULT_PORT and present the right prompt.
  local default
  if is_port_free "$DEFAULT_PORT"; then
    ok "$(t port_default_free "$DEFAULT_PORT")"
    default="$DEFAULT_PORT"
  else
    local owner; owner="$(who_uses_port "$DEFAULT_PORT")"
    warn "$(t port_default_in_use_warn "$DEFAULT_PORT" "$(fmt_owner_suffix "$owner")")"
    warn "$(t port_bind_conflict_warn)"
    info "$(t port_search_next)"
    if ! default="$(find_next_free_port $((DEFAULT_PORT + 1)))"; then
      err "$(t port_no_free_in_range "$DEFAULT_PORT" "$((DEFAULT_PORT + 100))")"
      return 1
    fi
    info "$(t port_suggested_alt "$default")"
  fi

  # Non-TTY guard: `curl ... | bash` ties stdin to the curl pipe so `read`
  # would deadlock. Tell the user how to re-run interactively (or set PORT).
  if [[ ! -t 0 ]]; then
    err "$(t port_stdin_not_tty)"
    echo
    echo "  $(t port_rerun_interactively)"
    echo "      bash <(curl -fsSL <installer-url>)"
    echo
    echo "  $(t port_or_set_explicitly)"
    echo "      PORT=${default} bash -c \"\$(curl -fsSL <installer-url>)\""
    echo
    return 1
  fi

  local prompt_msg; prompt_msg="$(t port_prompt "$default")"
  while true; do
    local reply
    read -r -p "$prompt_msg" reply
    case "$reply" in
      q|Q)
        info "$(t port_aborted)"
        return 1
        ;;
      "")
        PORT="$default"
        return 0
        ;;
      *)
        if [[ ! "$reply" =~ ^[0-9]+$ ]] || (( reply < 1024 || reply > 65535 )); then
          err "$(t port_invalid_retry)"
          continue
        fi
        if ! is_port_free "$reply"; then
          local who; who="$(who_uses_port "$reply")"
          err "$(t port_also_in_use "$reply" "$(fmt_owner_suffix "$who")")"
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

  err "$(t docker_not_found)"
  echo
  echo "${C_BOLD}$(t docker_required)${C_RESET}"
  echo "$(t docker_install_prompt)"
  echo

  local os
  os="$(detect_os)"
  case "$os" in
    macos)
      local arch
      arch="$(detect_mac_arch)"
      if [[ "$arch" == "apple-silicon" ]]; then
        echo "  • ${C_BOLD}$(t docker_orbstack)${C_RESET}"
        echo "      https://orbstack.dev/"
        echo "  • ${C_BOLD}$(t docker_desktop_apple)${C_RESET}"
        echo "      https://www.docker.com/products/docker-desktop/"
      else
        echo "  • ${C_BOLD}$(t docker_desktop_intel)${C_RESET}"
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
          echo "    $(t docker_logout_back_in)"
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
          echo "  $(t docker_linux_generic)"
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
  err "$(t docker_not_running)"
  echo
  case "$(detect_os)" in
    macos) echo "$(t docker_start_macos)" ;;
    linux) echo "$(t docker_start_linux)" ;;
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
    err "$(t docker_compose_missing)"
    echo "$(t docker_compose_install_hint)"
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
  info "$(t health_waiting "$HEALTH_TIMEOUT_SEC")"
  local end=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while (( $(date +%s) < end )); do
    if curl -fsS "$url" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "$(t health_ok "$url")"
      return 0
    fi
    sleep 2
    printf "."
  done
  printf "\n"
  err "$(t health_timeout "$HEALTH_TIMEOUT_SEC")"
  echo "  $(t health_inspect_logs "$CONTAINER_NAME")"
  return 1
}

# Print the post-install summary. When the chosen port is not the
# DigiCode UI's default (3001), the user has to set the matching port in
# the frontend's "ローカルサーバー" port input — the installer reminds
# them with the exact value to type.
print_install_summary() {
  echo
  ok "${C_BOLD}$(t summary_title)${C_RESET}"
  echo
  echo "${C_BOLD}$(t summary_next_steps)${C_RESET}"
  echo "  $(t summary_step1)"
  echo "  $(t summary_step2)"
  echo "  $(t summary_step3)"
  if (( PORT == DIGICODE_UI_PORT )); then
    echo "     $(t summary_default_match)"
  else
    echo "  ${C_BOLD}$(t summary_step4 "$PORT")${C_RESET}"
    echo "     $(t summary_step4_hint)"
  fi
  echo
  echo "${C_DIM}$(t summary_sanity)${C_RESET}  curl http://localhost:${PORT}/health"
  echo
  echo "${C_DIM}$(t summary_manage)${C_RESET}"
  echo "  • $(t summary_status_label)    bash $0 status"
  echo "  • $(t summary_stop_label)      bash $0 stop"
  echo "  • $(t summary_update_label)    bash $0 update"
  echo "  • $(t summary_uninstall_label) bash $0 uninstall"
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

  info "$(t install_writing_compose "$COMPOSE_FILE" "$PORT")"
  write_compose_file

  info "$(t install_pulling_image "$IMAGE")"
  docker_compose -f "$COMPOSE_FILE" pull

  info "$(t install_starting_container "$CONTAINER_NAME")"
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
    err "$(t update_compose_missing "$COMPOSE_FILE")"
    echo "  $(t update_run_install_first "$0")"
    exit 1
  fi
  read_port_from_compose
  info "$(t update_pulling_latest)"
  docker_compose -f "$COMPOSE_FILE" pull
  info "$(t update_recreating "$PORT")"
  docker_compose -f "$COMPOSE_FILE" up -d
  wait_for_health
}

cmd_uninstall() {
  require_docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    warn "$(t uninstall_compose_missing "$COMPOSE_FILE")"
    return 0
  fi

  echo "${C_BOLD}$(t uninstall_will_title)${C_RESET}"
  echo "  • $(t uninstall_will_stop "$CONTAINER_NAME")"
  echo "  • $(t uninstall_will_volumes)"
  echo "  • $(t uninstall_will_dir "$INSTALL_DIR")"
  echo
  local reply
  read -r -p "$(t uninstall_continue_prompt)" reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "$(t uninstall_cancelled)"; return 0 ;;
  esac

  info "$(t uninstall_stopping)"
  docker_compose -f "$COMPOSE_FILE" down -v || true

  info "$(t uninstall_removing_dir "$INSTALL_DIR")"
  rm -rf "$INSTALL_DIR"

  echo
  read -r -p "$(t uninstall_image_prompt "$IMAGE")" reply
  case "$reply" in
    y|Y|yes|YES)
      info "$(t uninstall_removing_image)"
      docker rmi "$IMAGE" 2>/dev/null || warn "$(t uninstall_image_not_found)"
      ;;
    *) ;;
  esac

  ok "$(t uninstall_complete)"
}

cmd_status() {
  require_docker
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "$(t status_not_installed "$CONTAINER_NAME")"
    echo "  $(t status_run_install "$0")"
    return 1
  fi

  read_port_from_compose

  local state image
  state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"

  local url; url="$(health_url)"
  echo "${C_BOLD}$(t status_container_label)${C_RESET}    ${CONTAINER_NAME}"
  echo "${C_BOLD}$(t status_state_label)${C_RESET}        ${state}"
  echo "${C_BOLD}$(t status_image_label)${C_RESET}        ${image}"
  echo "${C_BOLD}$(t status_host_port_label)${C_RESET}    ${PORT}"
  echo "${C_BOLD}$(t status_health_url_label)${C_RESET}   ${url}"
  echo "${C_BOLD}$(t status_compose_label)${C_RESET}      ${COMPOSE_FILE}"
  echo

  if [[ "$state" == "running" ]]; then
    if curl -fsS "$url" 2>/dev/null | grep -q '"status":"ok"'; then
      ok "$(t status_health_passed)"
    else
      warn "$(t status_health_not_responding)"
    fi
  fi
}

cmd_start() {
  require_docker
  require_docker_running
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "$(t start_compose_missing)"
    exit 1
  fi
  read_port_from_compose
  docker_compose -f "$COMPOSE_FILE" start
  wait_for_health
}

cmd_stop() {
  require_docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "$(t start_compose_missing)"
    exit 1
  fi
  docker_compose -f "$COMPOSE_FILE" stop
  ok "$(t stop_complete)"
}

# Help is intentionally English-only — it's a developer reference, all the
# subcommand names and CLI flags are English regardless of locale, and
# translating it adds maintenance burden without changing UX during a normal
# install/uninstall run.
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

Language (Tier 1: ja + en):
  • macOS: \$LANG (ja_*  -> ja, else en).  Linux: forced to en.
  • Override:  DIGICODE_LANG=ja  /  DIGICODE_LANG=en

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
          err "$(t port_flag_arg_required)"
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
  detect_lang
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
      err "$(t unknown_subcommand "$sub")"
      echo
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
