<#
.SYNOPSIS
  DigiCode local compile-server installer (Windows PowerShell).

.DESCRIPTION
  Pulls ghcr.io/fablab-westharima/digicode-compile-api:latest, starts it on
  port 3001 with persistent named volumes, then prints the next steps.
  Docker Desktop must be installed beforehand; the script aborts with a
  download URL if it is missing.

  Localization (Tier 1: ja + en):
    - Auto-detected from [CultureInfo]::CurrentUICulture.Name
      (ja-* -> ja; everything else -> en).
    - Override with $env:DIGICODE_LANG = 'ja' (or 'en').

.PARAMETER Subcommand
  install (default), update, uninstall, status, start, stop, help

.EXAMPLE
  irm https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.ps1 | iex

.EXAMPLE
  .\install.ps1 status

.LINK
  https://github.com/fablab-westharima/digicode-installer
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'uninstall', 'status', 'start', 'stop', 'help')]
    [string]$Subcommand = 'install',

    # --port N flag (alternative to the PORT env var). Skips the install prompt.
    [Parameter()]
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# UTF-8 console encoding
# ---------------------------------------------------------------------------
# PS 5.1 (the system PowerShell on most Win10/11 boxes) defaults to the
# console's OEM code page (CP932 on Japanese locale), so any Japanese
# string we print as UTF-8 ends up mojibake. Forcing OutputEncoding to
# UTF-8 fixes Write-Host / Read-Host display on modern conhost. We swallow
# any exception so the script still works on hosts that don't allow it
# (e.g. some restricted environments) — they just see the en fallback if
# the locale is ja.

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Best-effort: if the host blocks encoding changes, fall through silently.
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:Image            = 'ghcr.io/fablab-westharima/digicode-compile-api:latest'
$Script:ContainerName    = 'digicode-compile-api'
$Script:DefaultPort      = 3001
$Script:DigiCodeUiPort   = 3001  # the DigiCode UI's default - no extra step needed when Port matches
$Script:InstallDir       = Join-Path $env:USERPROFILE '.digicode\compile-server'
$Script:ComposeFile      = Join-Path $Script:InstallDir 'docker-compose.yml'
$Script:HealthTimeoutSec = 60

# Resolved host port for the running container — set by Pick-Port during
# install or by Read-PortFromCompose for subsequent commands.
$Script:Port             = if ($env:PORT) { [int]$env:PORT } else { 0 }

# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

$Script:LangCode = 'en'

function Detect-Lang {
    if ($env:DIGICODE_LANG) {
        if ($env:DIGICODE_LANG -match '^ja') {
            $Script:LangCode = 'ja'
        } else {
            $Script:LangCode = 'en'
        }
        return
    }
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
        if ($culture -match '^ja') {
            $Script:LangCode = 'ja'
        } else {
            $Script:LangCode = 'en'
        }
    } catch {
        $Script:LangCode = 'en'
    }
}

# English catalog
$Script:MessagesEn = @{
    docker_not_found             = 'Docker not found in PATH.'
    docker_required              = 'DigiCode local compile-server requires Docker Desktop.'
    docker_install_prompt        = 'Install Docker Desktop and re-run this script:'
    docker_store_recommended     = 'Microsoft Store (recommended)'
    docker_store_search_hint     = 'Search "Docker Desktop" in the Microsoft Store and click Install.'
    docker_store_publisher_check = 'Verify publisher is "Docker Inc" before installing.'
    docker_store_why             = 'No subprocess windows during install + automatic updates.'
    docker_direct_exe            = 'Direct installer (.exe)'
    docker_wsl2_hint             = '(WSL2 backend recommended; the installer will guide you.)'
    docker_direct_warning        = 'IMPORTANT: do not close any window the installer opens until it finishes — closing a spawned subprocess mid-install can leave C:\ProgramData\DockerDesktop in a broken state.'
    docker_alternatives          = 'Lightweight / OSS alternatives:'
    docker_troubleshoot_title    = 'If you hit "ProgramData\DockerDesktop must be owned by an elevated account":'
    docker_troubleshoot_hint     = 'Open Admin PowerShell, run the 4 commands below, then re-run the installer:'
    docker_troubleshoot_docs     = 'Full guide: https://code.fablab-westharima.jp/docs/local-compile-server'
    docker_not_running           = 'Docker is installed but not running.'
    docker_start_windows         = 'Start Docker Desktop from the Start menu, wait until the whale icon settles, then re-run this script.'
    docker_compose_missing       = "Neither 'docker compose' nor 'docker-compose' is available."
    docker_compose_install_hint  = 'Install the Docker Compose plugin (bundled with recent Docker).'

    port_invalid_range           = 'Invalid port {0}: must be 1024-65535.'
    port_in_use_env              = 'Port {0} is already in use{1}.'
    port_pick_different          = 'Pick a different port or stop the conflicting process.'
    port_using_env               = 'Using port {0} (set via -Port / PORT env).'
    port_default_free            = 'Port {0} is available.'
    port_default_in_use_warn     = 'Port {0} is already in use{1}.'
    port_bind_conflict_warn      = 'Binding the compile-server here would conflict with that process.'
    port_search_next             = 'Searching for the next free port...'
    port_no_free_in_range        = 'No free port found in {0}-{1}. Free a port and retry.'
    port_suggested_alt           = 'Suggested alternate: {0}'
    port_session_not_interactive = 'Cannot prompt for the port: the session is not interactive.'
    port_set_explicit_hint       = 'Set PORT explicitly to skip the prompt:'
    port_set_explicit_example    = '$env:PORT={0}; irm <installer-url> | iex'
    port_prompt                  = "Enter port to use [{0}] (Enter to accept, 'q' to abort)"
    port_aborted                 = 'Aborted by user.'
    port_invalid_retry           = 'Invalid port: must be an integer in 1024-65535. Try again.'
    port_also_in_use             = 'Port {0} is also in use{1}. Try another.'
    port_owner_by                = ' by {0}'
    port_owner_paren             = ' ({0})'

    health_waiting               = 'Waiting for compile-server to come up (timeout {0}s)...'
    health_ok                    = 'Compile-server is healthy at {0}'
    health_timeout               = 'Health check timed out after {0}s.'
    health_inspect_logs          = '  Inspect logs with:  docker logs {0}'

    summary_title                = 'DigiCode local compile-server is ready.'
    summary_next_steps           = 'Next steps:'
    summary_step1                = '  1. Open DigiCode in your browser (https://code.fablab-westharima.jp)'
    summary_step2                = '  2. Open Compile Settings (コンパイル設定)'
    summary_step3                = '  3. Pick Local Server (ローカルサーバー)'
    summary_default_match        = '     - the default port matches; nothing else to do.'
    summary_step4                = '  4. Set Port (ポート番号) to {0}'
    summary_step4_hint1          = '     so DigiCode talks to this server (the frontend persists this'
    summary_step4_hint2          = '     in localStorage for next time).'
    summary_sanity               = 'Sanity check:  curl http://localhost:{0}/health'
    summary_manage               = 'Manage the server:'
    summary_manage_status        = '  - Status:    .\install.ps1 status'
    summary_manage_stop          = '  - Stop:      .\install.ps1 stop'
    summary_manage_update        = '  - Update:    .\install.ps1 update'
    summary_manage_uninstall     = '  - Uninstall: .\install.ps1 uninstall'

    install_writing_compose      = 'Writing compose file to {0} (host port {1})'
    install_pulling_image        = 'Pulling {0} (~2.1 GB compressed, ~8.8 GB extracted on first run)...'
    install_starting_container   = 'Starting {0}...'

    update_compose_missing       = 'Compose file not found at {0}.'
    update_run_install_first     = "  Run '.\install.ps1 install' first."
    update_pulling_latest        = 'Pulling latest image...'
    update_recreating            = 'Recreating container (host port {0})...'

    uninstall_compose_missing    = 'Compose file not found at {0} - nothing to uninstall.'
    uninstall_will_title         = 'This will:'
    uninstall_will_stop          = '  - Stop and remove the {0} container'
    uninstall_will_volumes       = '  - Delete the persistent volumes (digicode-projects, digicode-cache)'
    uninstall_will_dir           = '  - Delete {0}'
    uninstall_continue_prompt    = 'Continue? [y/N]'
    uninstall_cancelled          = 'Cancelled.'
    uninstall_stopping           = 'Stopping container and removing volumes...'
    uninstall_removing_dir       = 'Removing {0}...'
    uninstall_image_prompt       = 'Also delete the Docker image ({0})? [y/N]'
    uninstall_removing_image     = 'Removing image...'
    uninstall_image_not_found    = 'Image not found (already removed?)'
    uninstall_complete           = 'Uninstall complete.'

    status_not_installed         = '{0} is not installed.'
    status_run_install           = "  Run '.\install.ps1 install' to set it up."
    status_container_label       = 'Container:    {0}'
    status_state_label           = 'State:        {0}'
    status_image_label           = 'Image:        {0}'
    status_host_port_label       = 'Host port:    {0}'
    status_health_url_label      = 'Health URL:   {0}'
    status_compose_label         = 'Compose:      {0}'
    status_health_passed         = 'Health check passed.'
    status_health_not_responding = 'Container is running but /health is not responding (still starting?).'

    start_compose_missing        = "Compose file not found - run 'install' first."
    stop_complete                = 'Stopped.'

    err_docker_not_installed     = 'Docker is not installed.'
    err_docker_not_running       = 'Docker is not running.'
    err_compose_plugin_missing   = 'docker compose plugin missing.'
    err_port_selection_failed    = 'Port selection failed.'
    err_health_check_failed      = 'Health check failed.'
    err_not_installed            = 'Not installed.'

    press_enter_to_close         = '(Press Enter to close this window.)'
}

# Japanese catalog. Same keys, translated for native speakers. Mixed
# Japanese / Latin / numbers stays half-width to avoid awkward spacing;
# 全角 punctuation only at sentence boundaries.
$Script:MessagesJa = @{
    docker_not_found             = 'Docker が PATH 上に見つかりません。'
    docker_required              = 'DigiCode のローカルコンパイルサーバーには Docker Desktop が必要です。'
    docker_install_prompt        = 'Docker Desktop をインストールしてからこのスクリプトを再実行してください:'
    docker_store_recommended     = 'Microsoft Store (推奨)'
    docker_store_search_hint     = 'Microsoft Store で「Docker Desktop」を検索して「インストール」をクリック。'
    docker_store_publisher_check = '発行元が「Docker Inc」であることを必ず確認してから install してください。'
    docker_store_why             = 'install 中に追加 window が出ない + 自動更新あり (一般 user 推奨)。'
    docker_direct_exe            = '直接 install (.exe)'
    docker_wsl2_hint             = '(WSL2 バックエンド推奨。インストーラーが案内します。)'
    docker_direct_warning        = '重要: インストーラーが開くすべての window は install 完了まで閉じないでください — 途中で window を閉じると C:\ProgramData\DockerDesktop が壊れた状態で残ります。'
    docker_alternatives          = '軽量 / OSS 代替:'
    docker_troubleshoot_title    = '「ProgramData\DockerDesktop must be owned by an elevated account」エラー時:'
    docker_troubleshoot_hint     = '管理者 PowerShell で下記 4 行を実行してから installer を再実行してください:'
    docker_troubleshoot_docs     = '詳細ガイド: https://code.fablab-westharima.jp/docs/local-compile-server'
    docker_not_running           = 'Docker はインストール済みですが起動していません。'
    docker_start_windows         = 'スタートメニューから Docker Desktop を起動し、鯨アイコンが安定するまで待ってからこのスクリプトを再実行してください。'
    docker_compose_missing       = "'docker compose' も 'docker-compose' も見つかりません。"
    docker_compose_install_hint  = 'Docker Compose プラグインをインストールしてください (最近の Docker には同梱されています)。'

    port_invalid_range           = 'ポート {0} は不正です: 1024〜65535 を指定してください。'
    port_in_use_env              = 'ポート {0} は既に使用されています{1}。'
    port_pick_different          = '別のポートを指定するか、競合しているプロセスを停止してください。'
    port_using_env               = 'ポート {0} を使用します (-Port / PORT 環境変数で指定)。'
    port_default_free            = 'ポート {0} は利用可能です。'
    port_default_in_use_warn     = 'ポート {0} は既に使用されています{1}。'
    port_bind_conflict_warn      = 'このポートでコンパイルサーバーを起動すると上記プロセスと競合します。'
    port_search_next             = '別の空きポートを検索しています...'
    port_no_free_in_range        = '{0}〜{1} の範囲に空きポートがありません。ポートを解放してから再実行してください。'
    port_suggested_alt           = '代替候補: {0}'
    port_session_not_interactive = 'ポートを問い合わせできません: 対話セッションではありません。'
    port_set_explicit_hint       = 'PORT を明示的に指定するとプロンプトをスキップできます:'
    port_set_explicit_example    = '$env:PORT={0}; irm <installer-url> | iex'
    port_prompt                  = "使用するポートを入力 [{0}] (Enter で確定、'q' で中止)"
    port_aborted                 = 'ユーザー操作により中止しました。'
    port_invalid_retry           = '不正なポートです: 1024〜65535 の整数を入力してください。'
    port_also_in_use             = 'ポート {0} も使用中です{1}。別のポートを指定してください。'
    port_owner_by                = ' ({0} が使用中)'
    port_owner_paren             = ' ({0})'

    health_waiting               = 'コンパイルサーバーの起動を待機中です (タイムアウト {0} 秒)...'
    health_ok                    = 'コンパイルサーバーは正常に稼働しています: {0}'
    health_timeout               = 'ヘルスチェックが {0} 秒でタイムアウトしました。'
    health_inspect_logs          = '  ログを確認:  docker logs {0}'

    summary_title                = 'DigiCode のローカルコンパイルサーバーが準備完了しました。'
    summary_next_steps           = '次のステップ:'
    summary_step1                = '  1. ブラウザで DigiCode を開く (https://code.fablab-westharima.jp)'
    summary_step2                = '  2. 「コンパイル設定」を開く'
    summary_step3                = '  3. 「ローカルサーバー」を選択'
    summary_default_match        = '     - デフォルトポートと一致するため、追加設定は不要。'
    summary_step4                = '  4. 「ポート番号」を {0} に設定'
    summary_step4_hint1          = '     これで DigiCode が本サーバーと通信します。設定はブラウザの'
    summary_step4_hint2          = '     localStorage に保存され、次回からは不要です。'
    summary_sanity               = '動作確認:  curl http://localhost:{0}/health'
    summary_manage               = 'サーバー管理:'
    summary_manage_status        = '  - 状態確認: .\install.ps1 status'
    summary_manage_stop          = '  - 停止:     .\install.ps1 stop'
    summary_manage_update        = '  - 更新:     .\install.ps1 update'
    summary_manage_uninstall     = '  - 削除:     .\install.ps1 uninstall'

    install_writing_compose      = 'compose ファイルを {0} に書き出し中 (ホストポート {1})'
    install_pulling_image        = '{0} をダウンロード中 (圧縮 ~2.1 GB / 展開後 ~8.8 GB、初回のみ)...'
    install_starting_container   = '{0} を起動中...'

    update_compose_missing       = 'compose ファイルが見つかりません: {0}'
    update_run_install_first     = "  先に '.\install.ps1 install' を実行してください。"
    update_pulling_latest        = '最新イメージをダウンロード中...'
    update_recreating            = 'コンテナを再作成中 (ホストポート {0})...'

    uninstall_compose_missing    = 'compose ファイルが見つかりません ({0}) — アンインストール対象がありません。'
    uninstall_will_title         = '以下を実行します:'
    uninstall_will_stop          = '  - {0} コンテナを停止して削除'
    uninstall_will_volumes       = '  - 永続ボリューム (digicode-projects、digicode-cache) を削除'
    uninstall_will_dir           = '  - {0} を削除'
    uninstall_continue_prompt    = '続行しますか? [y/N]'
    uninstall_cancelled          = 'キャンセルしました。'
    uninstall_stopping           = 'コンテナを停止しボリュームを削除中...'
    uninstall_removing_dir       = '{0} を削除中...'
    uninstall_image_prompt       = 'Docker イメージ ({0}) も削除しますか? [y/N]'
    uninstall_removing_image     = 'イメージを削除中...'
    uninstall_image_not_found    = 'イメージが見つかりません (既に削除済みの可能性)'
    uninstall_complete           = 'アンインストールが完了しました。'

    status_not_installed         = '{0} はインストールされていません。'
    status_run_install           = "  セットアップするには '.\install.ps1 install' を実行してください。"
    status_container_label       = 'コンテナ:        {0}'
    status_state_label           = '状態:            {0}'
    status_image_label           = 'イメージ:        {0}'
    status_host_port_label       = 'ホストポート:    {0}'
    status_health_url_label      = 'ヘルス URL:      {0}'
    status_compose_label         = 'Compose:         {0}'
    status_health_passed         = 'ヘルスチェック OK。'
    status_health_not_responding = 'コンテナは起動中ですが /health が応答しません (起動処理中の可能性)。'

    start_compose_missing        = "compose ファイルが見つかりません — 先に 'install' を実行してください。"
    stop_complete                = '停止しました。'

    err_docker_not_installed     = 'Docker がインストールされていません。'
    err_docker_not_running       = 'Docker が起動していません。'
    err_compose_plugin_missing   = 'docker compose プラグインが見つかりません。'
    err_port_selection_failed    = 'ポート選択に失敗しました。'
    err_health_check_failed      = 'ヘルスチェックに失敗しました。'
    err_not_installed            = 'インストールされていません。'

    press_enter_to_close         = '(Enter キーで閉じてください。)'
}

# t key [args...]  — return the localized string for `key`, with -f style
# {0} {1} substitution for args. Falls back to the en catalog if a key is
# missing in ja (defensive — shouldn't happen).
#
# Named the parameter $FmtArgs (not $Args) to avoid colliding with the
# automatic $args variable that PowerShell exposes inside every function.
function T {
    param(
        [Parameter(Mandatory)] [string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)] $FmtArgs
    )
    $catalog = if ($Script:LangCode -eq 'ja') { $Script:MessagesJa } else { $Script:MessagesEn }
    $fmt = $catalog[$Key]
    if (-not $fmt) {
        $fmt = $Script:MessagesEn[$Key]
    }
    if (-not $fmt) {
        return ''
    }
    if ($FmtArgs -and $FmtArgs.Count -gt 0) {
        return [string]::Format($fmt, [object[]]$FmtArgs)
    }
    return $fmt
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Info  { param([string]$Msg) Write-Host "▶ $Msg" -ForegroundColor Blue }
function Write-Ok    { param([string]$Msg) Write-Host "✅ $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "⚠️  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "❌ $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Port handling
# ---------------------------------------------------------------------------

function Test-PortFree {
    param([Parameter(Mandatory)] [int]$PortNumber)

    # Modern Windows (8.1+ / Server 2012 R2+) ships Get-NetTCPConnection.
    try {
        $listener = Get-NetTCPConnection `
            -LocalPort $PortNumber `
            -State Listen `
            -ErrorAction Stop
        if ($listener) { return $false }
    } catch {
        # No listener found → port is free
        return $true
    }
    return $true
}

# Walk upward from $StartPort until we find a free port, capped at +100.
function Find-NextFreePort {
    param([int]$StartPort = ($Script:DefaultPort + 1))
    for ($p = $StartPort; $p -lt ($StartPort + 100); $p++) {
        if (Test-PortFree -PortNumber $p) { return $p }
    }
    return 0
}

# Best-effort: return "<pid> (<process>)" of whoever holds the LISTEN socket
# on $PortNumber, or empty string when we can't resolve it.
function Get-PortOwner {
    param([Parameter(Mandatory)] [int]$PortNumber)
    try {
        $conn = Get-NetTCPConnection `
            -LocalPort $PortNumber `
            -State Listen `
            -ErrorAction Stop |
            Select-Object -First 1
        if (-not $conn) { return '' }
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) {
            return "$($conn.OwningProcess) ($($proc.ProcessName))"
        }
        return "$($conn.OwningProcess)"
    } catch {
        return ''
    }
}

# Wrap an owner string (e.g. "1234 (chrome)") into the localized "by ..."
# / " (...)" suffix used by port_in_use_env and port_default_in_use_warn.
# Empty input -> empty output.
function Format-OwnerSuffix {
    param([string]$Owner)
    if ([string]::IsNullOrEmpty($Owner)) { return '' }
    return (T 'port_owner_by' $Owner)
}

# Decide which host port to expose. Always prompts the user (per
# 2026-05-01 user direction) unless $Script:Port is already set (PORT env
# var or --port flag) or the host is non-interactive.
# Sets $Script:Port; returns $true on success, $false on user abort.
function Pick-Port {
    if ($Script:Port -gt 0) {
        if ($Script:Port -lt 1024 -or $Script:Port -gt 65535) {
            Write-Err (T 'port_invalid_range' $Script:Port)
            return $false
        }
        if (-not (Test-PortFree -PortNumber $Script:Port)) {
            $owner = Get-PortOwner -PortNumber $Script:Port
            Write-Err (T 'port_in_use_env' $Script:Port (Format-OwnerSuffix $owner))
            Write-Err (T 'port_pick_different')
            return $false
        }
        Write-Info (T 'port_using_env' $Script:Port)
        return $true
    }

    # Probe the default port and prepare a smart suggested default.
    $default = 0
    if (Test-PortFree -PortNumber $Script:DefaultPort) {
        Write-Ok (T 'port_default_free' $Script:DefaultPort)
        $default = $Script:DefaultPort
    } else {
        $owner = Get-PortOwner -PortNumber $Script:DefaultPort
        Write-Warn2 (T 'port_default_in_use_warn' $Script:DefaultPort (Format-OwnerSuffix $owner))
        Write-Warn2 (T 'port_bind_conflict_warn')
        Write-Info (T 'port_search_next')
        $default = Find-NextFreePort -StartPort ($Script:DefaultPort + 1)
        if (-not $default) {
            Write-Err (T 'port_no_free_in_range' $Script:DefaultPort ($Script:DefaultPort + 100))
            return $false
        }
        Write-Info (T 'port_suggested_alt' $default)
    }

    # Non-interactive guard. PowerShell exposes [Environment]::UserInteractive,
    # but `irm | iex` sometimes still has it set to true while stdin is bound
    # to the pipe. Read-Host falls through cleanly in iex if a console is
    # attached, so we just rely on it and trap the error case.
    if (-not [Environment]::UserInteractive) {
        Write-Err (T 'port_session_not_interactive')
        Write-Host ''
        Write-Host ('  ' + (T 'port_set_explicit_hint'))
        Write-Host ('      ' + (T 'port_set_explicit_example' $default))
        Write-Host ''
        return $false
    }

    while ($true) {
        $reply = Read-Host (T 'port_prompt' $default)
        if ($reply -eq 'q' -or $reply -eq 'Q') {
            Write-Info (T 'port_aborted')
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($reply)) {
            $Script:Port = $default
            return $true
        }
        if ($reply -notmatch '^[0-9]+$') {
            Write-Err (T 'port_invalid_retry')
            continue
        }
        $candidate = [int]$reply
        if ($candidate -lt 1024 -or $candidate -gt 65535) {
            Write-Err (T 'port_invalid_retry')
            continue
        }
        if (-not (Test-PortFree -PortNumber $candidate)) {
            $who = Get-PortOwner -PortNumber $candidate
            Write-Err (T 'port_also_in_use' $candidate (Format-OwnerSuffix $who))
            continue
        }
        $Script:Port = $candidate
        return $true
    }
}

# Read the active host port from an existing docker-compose.yml. Used by
# update / status / start / stop so they don't have to re-prompt.
function Read-PortFromCompose {
    if (-not (Test-Path $Script:ComposeFile)) {
        $Script:Port = $Script:DefaultPort
        return
    }
    $line = Select-String -Path $Script:ComposeFile -Pattern '^\s+-\s+"(\d+):\d+"' |
        Select-Object -First 1
    if ($line -and $line.Matches[0].Groups.Count -ge 2) {
        $Script:Port = [int]$line.Matches[0].Groups[1].Value
    } else {
        $Script:Port = $Script:DefaultPort
    }
}

function Get-HealthUrl {
    return "http://localhost:$($Script:Port)/health"
}

# ---------------------------------------------------------------------------
# Docker / Compose preflight
# ---------------------------------------------------------------------------

function Require-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return }

    Write-Err (T 'docker_not_found')
    Write-Host ''
    Write-Host (T 'docker_required') -ForegroundColor Cyan
    Write-Host (T 'docker_install_prompt')
    Write-Host ''
    # Recommend the Store install first — it's MSIX-managed, doesn't spawn
    # the cmd/PowerShell subprocess windows that beginners tend to close
    # accidentally, and auto-updates. The direct .exe install is kept as
    # an explicit alternative with a strong warning about not closing
    # spawned windows mid-install (the failure mode that produced the
    # "ProgramData/DockerDesktop must be owned by an elevated account"
    # error documented under "Troubleshooting" below).
    Write-Host ('  🥇 ' + (T 'docker_store_recommended')) -ForegroundColor Green
    Write-Host ('      ' + (T 'docker_store_search_hint'))
    Write-Host ('      ' + (T 'docker_store_publisher_check'))
    Write-Host ('      ' + (T 'docker_store_why')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  • ' + (T 'docker_direct_exe')) -ForegroundColor Cyan
    Write-Host '      https://www.docker.com/products/docker-desktop/'
    Write-Host ('      ' + (T 'docker_wsl2_hint'))
    Write-Host ('      ⚠️  ' + (T 'docker_direct_warning')) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ('  • ' + (T 'docker_alternatives'))
    Write-Host '      - Rancher Desktop:  https://rancherdesktop.io/'
    Write-Host '      - Podman Desktop:   https://podman-desktop.io/'
    Write-Host ''
    Write-Host ('📋 ' + (T 'docker_troubleshoot_title')) -ForegroundColor Yellow
    Write-Host ('   ' + (T 'docker_troubleshoot_hint'))
    Write-Host ''
    Write-Host '     Remove-Item "C:\ProgramData\DockerDesktop" -Recurse -Force'
    Write-Host '     New-Item -ItemType Directory -Path "C:\ProgramData\DockerDesktop" -Force | Out-Null'
    Write-Host '     icacls "C:\ProgramData\DockerDesktop" /setowner "*S-1-5-32-544" /T'
    Write-Host '     icacls "C:\ProgramData\DockerDesktop" /grant "*S-1-5-32-544:(OI)(CI)F" /T'
    Write-Host ''
    Write-Host ('   ' + (T 'docker_troubleshoot_docs')) -ForegroundColor DarkGray
    Write-Host ''
    throw (T 'err_docker_not_installed')
}

function Require-DockerRunning {
    try {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    } catch {}

    Write-Err (T 'docker_not_running')
    Write-Host ''
    Write-Host (T 'docker_start_windows')
    Write-Host ''
    throw (T 'err_docker_not_running')
}

# `docker compose` (plugin) vs the legacy `docker-compose` binary. Prefer
# the plugin, which is what every modern Docker install ships.
function Invoke-DockerCompose {
    param([Parameter(ValueFromRemainingArguments)] $Args)
    try {
        docker compose version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & docker compose @Args
            return
        }
    } catch {}

    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        & docker-compose @Args
        return
    }

    Write-Err (T 'docker_compose_missing')
    Write-Host (T 'docker_compose_install_hint')
    throw (T 'err_compose_plugin_missing')
}

# ---------------------------------------------------------------------------
# docker-compose.yml generation
# ---------------------------------------------------------------------------

function Write-ComposeFile {
    if (-not (Test-Path $Script:InstallDir)) {
        New-Item -ItemType Directory -Force -Path $Script:InstallDir | Out-Null
    }
    $content = @"
# Generated by DigiCode local-compile installer.
# Edit at your own risk - re-running 'install' overwrites this file.
# Host port: $($Script:Port) (chosen interactively, override with PORT env var or -Port flag).
services:
  digicode-compile-api:
    image: $($Script:Image)
    container_name: $($Script:ContainerName)
    ports:
      # The container listens on its built-in default (3001); we map it
      # to whatever host port the user picked.
      - "$($Script:Port):3001"
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
"@
    Set-Content -Path $Script:ComposeFile -Value $content -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

function Wait-ForHealth {
    $url = Get-HealthUrl
    Write-Info (T 'health_waiting' $Script:HealthTimeoutSec)
    $deadline = (Get-Date).AddSeconds($Script:HealthTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.Content -match '"status":"ok"') {
                Write-Ok (T 'health_ok' $url)
                return $true
            }
        } catch {}
        Start-Sleep -Seconds 2
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    Write-Err (T 'health_timeout' $Script:HealthTimeoutSec)
    Write-Host (T 'health_inspect_logs' $Script:ContainerName)
    return $false
}

function Write-InstallSummary {
    Write-Host ''
    Write-Ok (T 'summary_title')
    Write-Host ''
    Write-Host (T 'summary_next_steps') -ForegroundColor Cyan
    Write-Host (T 'summary_step1')
    Write-Host (T 'summary_step2')
    Write-Host (T 'summary_step3')
    if ($Script:Port -eq $Script:DigiCodeUiPort) {
        Write-Host (T 'summary_default_match')
    } else {
        Write-Host (T 'summary_step4' $Script:Port)
        Write-Host (T 'summary_step4_hint1')
        Write-Host (T 'summary_step4_hint2')
    }
    Write-Host ''
    Write-Host (T 'summary_sanity' $Script:Port) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host (T 'summary_manage') -ForegroundColor DarkGray
    Write-Host (T 'summary_manage_status')
    Write-Host (T 'summary_manage_stop')
    Write-Host (T 'summary_manage_update')
    Write-Host (T 'summary_manage_uninstall')
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

function Cmd-Install {
    Require-Docker
    Require-DockerRunning

    if (-not (Pick-Port)) { throw (T 'err_port_selection_failed') }

    Write-Info (T 'install_writing_compose' $Script:ComposeFile $Script:Port)
    Write-ComposeFile

    Write-Info (T 'install_pulling_image' $Script:Image)
    Invoke-DockerCompose -f $Script:ComposeFile pull

    Write-Info (T 'install_starting_container' $Script:ContainerName)
    Invoke-DockerCompose -f $Script:ComposeFile up -d

    if (-not (Wait-ForHealth)) { throw (T 'err_health_check_failed') }

    Write-InstallSummary
}

function Cmd-Update {
    Require-Docker
    Require-DockerRunning
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err (T 'update_compose_missing' $Script:ComposeFile)
        Write-Host (T 'update_run_install_first')
        throw (T 'err_not_installed')
    }
    Read-PortFromCompose
    Write-Info (T 'update_pulling_latest')
    Invoke-DockerCompose -f $Script:ComposeFile pull
    Write-Info (T 'update_recreating' $Script:Port)
    Invoke-DockerCompose -f $Script:ComposeFile up -d
    Wait-ForHealth | Out-Null
}

function Cmd-Uninstall {
    Require-Docker
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Warn2 (T 'uninstall_compose_missing' $Script:ComposeFile)
        return
    }

    Write-Host (T 'uninstall_will_title') -ForegroundColor Cyan
    Write-Host (T 'uninstall_will_stop' $Script:ContainerName)
    Write-Host (T 'uninstall_will_volumes')
    Write-Host (T 'uninstall_will_dir' $Script:InstallDir)
    Write-Host ''
    $reply = Read-Host (T 'uninstall_continue_prompt')
    if ($reply -notmatch '^(y|Y|yes|YES)$') {
        Write-Host (T 'uninstall_cancelled')
        return
    }

    Write-Info (T 'uninstall_stopping')
    try { Invoke-DockerCompose -f $Script:ComposeFile down -v } catch {}

    Write-Info (T 'uninstall_removing_dir' $Script:InstallDir)
    Remove-Item -Recurse -Force $Script:InstallDir -ErrorAction SilentlyContinue

    Write-Host ''
    $reply = Read-Host (T 'uninstall_image_prompt' $Script:Image)
    if ($reply -match '^(y|Y|yes|YES)$') {
        Write-Info (T 'uninstall_removing_image')
        try { docker rmi $Script:Image } catch { Write-Warn2 (T 'uninstall_image_not_found') }
    }

    Write-Ok (T 'uninstall_complete')
}

function Cmd-Status {
    Require-Docker
    $names = (docker ps -a --format '{{.Names}}') -split "`n"
    if ($names -notcontains $Script:ContainerName) {
        Write-Warn2 (T 'status_not_installed' $Script:ContainerName)
        Write-Host (T 'status_run_install')
        return
    }

    Read-PortFromCompose

    $state = (docker inspect -f '{{.State.Status}}' $Script:ContainerName 2>$null)
    $image = (docker inspect -f '{{.Config.Image}}' $Script:ContainerName 2>$null)
    $url = Get-HealthUrl

    Write-Host (T 'status_container_label' $Script:ContainerName) -ForegroundColor Cyan
    Write-Host (T 'status_state_label' $state)
    Write-Host (T 'status_image_label' $image)
    Write-Host (T 'status_host_port_label' $Script:Port)
    Write-Host (T 'status_health_url_label' $url)
    Write-Host (T 'status_compose_label' $Script:ComposeFile)
    Write-Host ''

    if ($state -eq 'running') {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.Content -match '"status":"ok"') {
                Write-Ok (T 'status_health_passed')
            } else {
                Write-Warn2 (T 'status_health_not_responding')
            }
        } catch {
            Write-Warn2 (T 'status_health_not_responding')
        }
    }
}

function Cmd-Start {
    Require-Docker
    Require-DockerRunning
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err (T 'start_compose_missing')
        throw (T 'err_not_installed')
    }
    Read-PortFromCompose
    Invoke-DockerCompose -f $Script:ComposeFile start
    Wait-ForHealth | Out-Null
}

function Cmd-Stop {
    Require-Docker
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err (T 'start_compose_missing')
        throw (T 'err_not_installed')
    }
    Invoke-DockerCompose -f $Script:ComposeFile stop
    Write-Ok (T 'stop_complete')
}

# Help is intentionally English-only — it's a developer reference, all the
# subcommand names and CLI flags are English regardless of locale, and
# translating it adds maintenance burden without changing UX during a
# normal install/uninstall run.
function Cmd-Help {
    $shownPort = if ($Script:Port -gt 0) { $Script:Port } else { $Script:DefaultPort }
    Write-Host @"
DigiCode local compile-server installer

Usage: .\install.ps1 [subcommand] [-Port N]

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
  - install always asks which host port to use, with a smart default
    ($($Script:DefaultPort) if free, or the next free port if $($Script:DefaultPort) is taken).
  - Pass -Port N or set `$env:PORT=N to skip the prompt
    (useful when piping irm | iex where stdin is not interactive).
  - update / status / start / stop read the active port from the
    generated compose file, so they stay in sync automatically.

Language (Tier 1: ja + en):
  - Auto-detected from CurrentUICulture (ja-* -> ja, else en).
  - Override:  `$env:DIGICODE_LANG = 'ja'   (or 'en')

Install dir:    $($Script:InstallDir)
Image:          $($Script:Image)
Default port:   $($Script:DefaultPort)  (also DigiCode UI's default; UI accepts custom ports)
Health URL:     http://localhost:$shownPort/health

Docs (5 langs): https://code.fablab-westharima.jp/docs/local-compile-server
"@ -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Resolve language before anything else so even early errors are localized.
Detect-Lang

# `-Port N` from the param block wins over the PORT env var (which we
# captured into $Script:Port at the top of the file). Re-apply only when
# the user passed an explicit -Port value.
if ($Port -gt 0) { $Script:Port = $Port }

# When this script is fetched via `irm | iex`, calling `exit` terminates the
# entire PowerShell host (the user's window closes before they can read the
# error). We `throw` from the subcommands instead and pause here so the user
# can see what went wrong before deciding what to do next.
try {
    switch ($Subcommand) {
        'install'   { Cmd-Install }
        'update'    { Cmd-Update }
        'uninstall' { Cmd-Uninstall }
        'status'    { Cmd-Status }
        'start'     { Cmd-Start }
        'stop'      { Cmd-Stop }
        'help'      { Cmd-Help }
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host ''
    Write-Host (T 'press_enter_to_close') -ForegroundColor DarkGray
    try { Read-Host | Out-Null } catch {}
}
