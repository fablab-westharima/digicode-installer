<#
.SYNOPSIS
  DigiCode local compile-server installer (Windows PowerShell).

.DESCRIPTION
  Pulls ghcr.io/fablab-westharima/digicode-compile-api:latest, starts it on
  port 3001 with persistent named volumes, then prints the next steps.
  Docker Desktop must be installed beforehand; the script aborts with a
  download URL if it is missing.

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

# Decide which host port to expose. Always prompts the user (per
# 2026-05-01 user direction) unless $Script:Port is already set (PORT env
# var or --port flag) or the host is non-interactive.
# Sets $Script:Port; returns $true on success, $false on user abort.
function Pick-Port {
    if ($Script:Port -gt 0) {
        if ($Script:Port -lt 1024 -or $Script:Port -gt 65535) {
            Write-Err "Invalid port $($Script:Port): must be 1024-65535."
            return $false
        }
        if (-not (Test-PortFree -PortNumber $Script:Port)) {
            $owner = Get-PortOwner -PortNumber $Script:Port
            Write-Err "Port $($Script:Port) is already in use$(if ($owner) { ' by ' + $owner })."
            Write-Err "Pick a different port or stop the conflicting process."
            return $false
        }
        Write-Info "Using port $($Script:Port) (set via -Port / PORT env)."
        return $true
    }

    # Probe the default port and prepare a smart suggested default.
    $default = 0
    if (Test-PortFree -PortNumber $Script:DefaultPort) {
        Write-Ok "Port $($Script:DefaultPort) is available."
        $default = $Script:DefaultPort
    } else {
        $owner = Get-PortOwner -PortNumber $Script:DefaultPort
        Write-Warn2 "Port $($Script:DefaultPort) is already in use$(if ($owner) { ' by ' + $owner })."
        Write-Warn2 "Binding the compile-server here would conflict with that process."
        Write-Info "Searching for the next free port..."
        $default = Find-NextFreePort -StartPort ($Script:DefaultPort + 1)
        if (-not $default) {
            Write-Err "No free port found in $($Script:DefaultPort)-$($Script:DefaultPort + 100). Free a port and retry."
            return $false
        }
        Write-Info "Suggested alternate: $default"
    }

    # Non-interactive guard. PowerShell exposes [Environment]::UserInteractive,
    # but `irm | iex` sometimes still has it set to true while stdin is bound
    # to the pipe. Read-Host falls through cleanly in iex if a console is
    # attached, so we just rely on it and trap the error case.
    if (-not [Environment]::UserInteractive) {
        Write-Err "Cannot prompt for the port: the session is not interactive."
        Write-Host ""
        Write-Host "  Set PORT explicitly to skip the prompt:"
        Write-Host "      `$env:PORT=$default; irm <installer-url> | iex"
        Write-Host ""
        return $false
    }

    while ($true) {
        $reply = Read-Host "Enter port to use [$default] (Enter to accept, 'q' to abort)"
        if ($reply -eq 'q' -or $reply -eq 'Q') {
            Write-Info "Aborted by user."
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($reply)) {
            $Script:Port = $default
            return $true
        }
        if ($reply -notmatch '^[0-9]+$') {
            Write-Err "Invalid port: must be an integer in 1024-65535. Try again."
            continue
        }
        $candidate = [int]$reply
        if ($candidate -lt 1024 -or $candidate -gt 65535) {
            Write-Err "Invalid port: must be 1024-65535. Try again."
            continue
        }
        if (-not (Test-PortFree -PortNumber $candidate)) {
            $who = Get-PortOwner -PortNumber $candidate
            Write-Err "Port $candidate is also in use$(if ($who) { ' (' + $who + ')' }). Try another."
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

    Write-Err "Docker not found in PATH."
    Write-Host ""
    Write-Host "DigiCode local compile-server requires Docker Desktop." -ForegroundColor Cyan
    Write-Host "Please install Docker for Windows and re-run this script:"
    Write-Host ""
    Write-Host "  • Docker Desktop for Windows" -ForegroundColor Cyan
    Write-Host "      https://www.docker.com/products/docker-desktop/"
    Write-Host "      (WSL2 backend recommended; the installer will guide you.)"
    Write-Host ""
    Write-Host "  • Alternatives (lightweight, OSS):"
    Write-Host "      - Rancher Desktop:  https://rancherdesktop.io/"
    Write-Host "      - Podman Desktop:   https://podman-desktop.io/"
    Write-Host ""
    exit 1
}

function Require-DockerRunning {
    try {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    } catch {}

    Write-Err "Docker is installed but not running."
    Write-Host ""
    Write-Host "Start Docker Desktop from the Start menu, wait until the whale"
    Write-Host "icon settles, then re-run this script."
    Write-Host ""
    exit 1
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

    Write-Err "Neither 'docker compose' nor 'docker-compose' is available."
    Write-Host "Install the Docker Compose plugin (bundled with recent Docker)."
    exit 1
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
    Write-Info "Waiting for compile-server to come up (timeout $($Script:HealthTimeoutSec)s)..."
    $deadline = (Get-Date).AddSeconds($Script:HealthTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.Content -match '"status":"ok"') {
                Write-Ok "Compile-server is healthy at $url"
                return $true
            }
        } catch {}
        Start-Sleep -Seconds 2
        Write-Host "." -NoNewline
    }
    Write-Host ""
    Write-Err "Health check timed out after $($Script:HealthTimeoutSec)s."
    Write-Host "  Inspect logs with:  docker logs $($Script:ContainerName)"
    return $false
}

function Write-InstallSummary {
    Write-Host ""
    Write-Ok "DigiCode local compile-server is ready."
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Open DigiCode in your browser (https://code.fablab-westharima.jp)"
    Write-Host "  2. Open Compile Settings (コンパイル設定)"
    Write-Host "  3. Pick Local Server (ローカルサーバー)"
    if ($Script:Port -eq $Script:DigiCodeUiPort) {
        Write-Host "     - the default port matches; nothing else to do."
    } else {
        Write-Host "  4. Set Port (ポート番号) to $($Script:Port)"
        Write-Host "     so DigiCode talks to this server (the frontend persists this"
        Write-Host "     in localStorage for next time)."
    }
    Write-Host ""
    Write-Host "Sanity check:  curl http://localhost:$($Script:Port)/health" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Manage the server:" -ForegroundColor DarkGray
    Write-Host "  - Status:    .\install.ps1 status"
    Write-Host "  - Stop:      .\install.ps1 stop"
    Write-Host "  - Update:    .\install.ps1 update"
    Write-Host "  - Uninstall: .\install.ps1 uninstall"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

function Cmd-Install {
    Require-Docker
    Require-DockerRunning

    if (-not (Pick-Port)) { exit 1 }

    Write-Info "Writing compose file to $($Script:ComposeFile) (host port $($Script:Port))"
    Write-ComposeFile

    Write-Info "Pulling $($Script:Image) (~2.1 GB compressed, ~8.8 GB extracted on first run)..."
    Invoke-DockerCompose -f $Script:ComposeFile pull

    Write-Info "Starting $($Script:ContainerName)..."
    Invoke-DockerCompose -f $Script:ComposeFile up -d

    if (-not (Wait-ForHealth)) { exit 1 }

    Write-InstallSummary
}

function Cmd-Update {
    Require-Docker
    Require-DockerRunning
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err "Compose file not found at $($Script:ComposeFile)."
        Write-Host "  Run '.\install.ps1 install' first."
        exit 1
    }
    Read-PortFromCompose
    Write-Info "Pulling latest image..."
    Invoke-DockerCompose -f $Script:ComposeFile pull
    Write-Info "Recreating container (host port $($Script:Port))..."
    Invoke-DockerCompose -f $Script:ComposeFile up -d
    Wait-ForHealth | Out-Null
}

function Cmd-Uninstall {
    Require-Docker
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Warn2 "Compose file not found at $($Script:ComposeFile) - nothing to uninstall."
        return
    }

    Write-Host "This will:" -ForegroundColor Cyan
    Write-Host "  - Stop and remove the $($Script:ContainerName) container"
    Write-Host "  - Delete the persistent volumes (digicode-projects, digicode-cache)"
    Write-Host "  - Delete $($Script:InstallDir)"
    Write-Host ""
    $reply = Read-Host "Continue? [y/N]"
    if ($reply -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "Cancelled."
        return
    }

    Write-Info "Stopping container and removing volumes..."
    try { Invoke-DockerCompose -f $Script:ComposeFile down -v } catch {}

    Write-Info "Removing $($Script:InstallDir)..."
    Remove-Item -Recurse -Force $Script:InstallDir -ErrorAction SilentlyContinue

    Write-Host ""
    $reply = Read-Host "Also delete the Docker image ($($Script:Image))? [y/N]"
    if ($reply -match '^(y|Y|yes|YES)$') {
        Write-Info "Removing image..."
        try { docker rmi $Script:Image } catch { Write-Warn2 "Image not found (already removed?)" }
    }

    Write-Ok "Uninstall complete."
}

function Cmd-Status {
    Require-Docker
    $names = (docker ps -a --format '{{.Names}}') -split "`n"
    if ($names -notcontains $Script:ContainerName) {
        Write-Warn2 "$($Script:ContainerName) is not installed."
        Write-Host "  Run '.\install.ps1 install' to set it up."
        return
    }

    Read-PortFromCompose

    $state = (docker inspect -f '{{.State.Status}}' $Script:ContainerName 2>$null)
    $image = (docker inspect -f '{{.Config.Image}}' $Script:ContainerName 2>$null)
    $url = Get-HealthUrl

    Write-Host "Container:    $($Script:ContainerName)" -ForegroundColor Cyan
    Write-Host "State:        $state"
    Write-Host "Image:        $image"
    Write-Host "Host port:    $($Script:Port)"
    Write-Host "Health URL:   $url"
    Write-Host "Compose:      $($Script:ComposeFile)"
    Write-Host ""

    if ($state -eq 'running') {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.Content -match '"status":"ok"') {
                Write-Ok "Health check passed."
            } else {
                Write-Warn2 "Container is running but /health is not responding (still starting?)."
            }
        } catch {
            Write-Warn2 "Container is running but /health is not responding (still starting?)."
        }
    }
}

function Cmd-Start {
    Require-Docker
    Require-DockerRunning
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err "Compose file not found - run 'install' first."
        exit 1
    }
    Read-PortFromCompose
    Invoke-DockerCompose -f $Script:ComposeFile start
    Wait-ForHealth | Out-Null
}

function Cmd-Stop {
    Require-Docker
    if (-not (Test-Path $Script:ComposeFile)) {
        Write-Err "Compose file not found - run 'install' first."
        exit 1
    }
    Invoke-DockerCompose -f $Script:ComposeFile stop
    Write-Ok "Stopped."
}

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

# `-Port N` from the param block wins over the PORT env var (which we
# captured into $Script:Port at the top of the file). Re-apply only when
# the user passed an explicit -Port value.
if ($Port -gt 0) { $Script:Port = $Port }

switch ($Subcommand) {
    'install'   { Cmd-Install }
    'update'    { Cmd-Update }
    'uninstall' { Cmd-Uninstall }
    'status'    { Cmd-Status }
    'start'     { Cmd-Start }
    'stop'      { Cmd-Stop }
    'help'      { Cmd-Help }
}
