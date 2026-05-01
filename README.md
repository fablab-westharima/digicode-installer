# DigiCode local compile-server installer

One-command installer for the DigiCode local compile-server
(`ghcr.io/fablab-westharima/digicode-compile-api:latest`).

> **Public mirror** of
> [`fablab-westharima/digicode/scripts/local-compile/`](https://github.com/fablab-westharima/digicode-installer)
> — the upstream lives in the private DigiCode monorepo; this repo is
> updated by hand when the upstream changes (license: MIT).

---

## Quick install

### macOS / Linux

```bash
# preferred — keeps stdin attached so the installer can prompt for the port
bash <(curl -fsSL https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.sh)
```

```bash
# non-interactive (no port prompt) — pin the port up front
PORT=3001 bash -c "$(curl -fsSL https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.sh)"
```

> `curl ... | bash` also works in **non-interactive** mode only — if you
> use it, set `PORT=N` first; otherwise the installer aborts with
> instructions because `read` cannot reach a terminal.

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.ps1 | iex
```

```powershell
# non-interactive (no port prompt)
$env:PORT = 3001
irm https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.ps1 | iex
```

That's it. The script:

1. Checks Docker is installed (prints OS-specific download URL if not, then exits)
2. Checks Docker daemon is running
3. **Asks which host port to use** (default 3001, or the next free port if
   3001 is taken — Enter to accept, type a custom port, or `q` to abort)
4. Writes `~/.digicode/compile-server/docker-compose.yml`
5. Pulls `ghcr.io/fablab-westharima/digicode-compile-api:latest` (~1 GB compressed)
6. Starts the container on the chosen port with persistent named volumes
7. Verifies `http://localhost:<port>/health` returns `{"status":"ok"}`
8. Prints the next step (toggle DigiCode → 「ローカルサーバー」)

> ⚠️ DigiCode's UI 「ローカルサーバー」 toggle currently hard-codes
> `http://localhost:3001`. If you pick a different port, the toggle
> won't see the server until the frontend port-setting UI ships
> (post-MVP). The installer prints this warning at the end of install
> when port ≠ 3001.

---

## Requirements

- **Docker** 20.10+ with the Compose plugin (recent Docker installs ship it).
  - macOS: [OrbStack](https://orbstack.dev/) (recommended on Apple Silicon) or
    [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  - Windows: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
    (WSL2 backend; the installer guides you)
  - Linux: `docker.io` + `docker-compose-plugin` from your distro's package manager
- **~4 GB** free disk for the image
- A wired or fast wireless connection for the first pull (~1 GB compressed,
  ~1–2 minutes on 100 Mbps fibre)

---

## Subcommands

```bash
bash install.sh [subcommand] [--port N]
# or on Windows:
.\install.ps1 [subcommand] [-Port N]
```

| Subcommand     | Action                                                                          |
| -------------- | ------------------------------------------------------------------------------- |
| `install`      | (default) prompt for port, pull image, start container, wait for `/health`      |
| `update`       | pull latest image and recreate the container (keeps the previous port)          |
| `uninstall`    | stop + remove container, delete volumes and install dir (asks for image)        |
| `status`       | show container state, image, host port, and a live health check                 |
| `start`        | start an existing (stopped) container                                           |
| `stop`         | stop the container without removing it                                          |
| `help`         | show built-in usage                                                             |

`update` / `status` / `start` / `stop` read the active host port from the
generated `docker-compose.yml`, so they don't need a port argument.

### Port selection

`install` always asks which host port to expose, with a smart default:

- If port `3001` is **free**: default = `3001` (just press Enter)
- If port `3001` is **in use**: the installer surfaces who's using it
  (best-effort) and suggests the next free port (e.g., `3002`)

To skip the prompt (for `curl | bash` / `irm | iex` pipelines, or for CI):

```bash
PORT=3001 bash install.sh                 # env var
bash install.sh install --port 3001       # CLI flag
```

```powershell
$env:PORT = 3001; .\install.ps1           # env var
.\install.ps1 install -Port 3001          # named param
```

### Examples

```bash
bash install.sh                       # first-time install (prompts for port)
bash install.sh install --port 3005   # pin a specific port, no prompt
bash install.sh status                # is it running and healthy?
bash install.sh update                # pull a new image and restart
bash install.sh stop                  # stop without losing the cache
bash install.sh start                 # bring it back up
bash install.sh uninstall             # nuke everything (asks twice)
```

---

## Where things live

| Item                  | Location                                                |
| --------------------- | ------------------------------------------------------- |
| `docker-compose.yml`  | `~/.digicode/compile-server/docker-compose.yml`         |
| Persistent projects   | named volume `digicode-projects`                        |
| Persistent cache      | named volume `digicode-cache`                           |
| Container             | `digicode-compile-api`                                  |
| Health endpoint       | `http://localhost:3001/health`                          |

The named volumes mean **stop / start / update preserves your build cache**
— a 1-byte source change after first cold compile takes ~9.6 s, an unchanged
re-compile takes ~1 ms (cache HIT).

---

## Compile latency expectations

| Scenario                                    | Wall time |
| ------------------------------------------- | --------- |
| First compile after `install` (cold + DL)   | 30–60 s   |
| Source-only change (warm rebuild)           | ~9.6 s    |
| Identical source compile (cache HIT)        | ~1 ms     |

These match the cloud server (ML30) — both run the same image, so the binary
output is bit-identical (no library drift).

---

## Why local?

| Plan        | Recommended? | Why                                                          |
| ----------- | :----------: | ------------------------------------------------------------ |
| Free        | —            | The 50 cloud compiles/month is usually enough                |
| Lite        | ▲            | Consider it if you exceed 250/month                          |
| Pro         | ◎            | Even 500/month can be tight for heavy users                  |
| Enterprise  | ◎            | Class-wide compile speedup; offline classroom support        |

Plus:

- **Unlimited compiles** — local doesn't count against the cloud quota.
- **Lower latency** — no network round trip; warm rebuilds in seconds.
- **Offline** — once the image is pulled, no internet required.
- **Identical output** — same Docker image as the cloud server.

---

## Troubleshooting

### "Docker not found"

Install Docker for your platform; the script printed the URL.

### "Docker is installed but not running"

Start Docker Desktop (or OrbStack) and wait until the whale/orb icon
settles, then re-run.

### "Health check timed out"

Cold first start can be slow on weak hardware. Inspect the container logs:

```bash
docker logs digicode-compile-api
```

If you see a panic, file an issue at
<https://github.com/fablab-westharima/digicode-installer/issues>
with the log excerpt.

### Port 3001 already in use

The installer detects this and asks for an alternate port — accept the
suggested next-free port (e.g., 3002) or type your own. The compose file
will be generated with that port automatically.

**Caveat:** DigiCode's "ローカルサーバー" toggle in the UI currently
hard-codes port 3001. If you pick a different port, the toggle won't
reach this server until the frontend port-setting UI ships (post-MVP);
the installer prints a warning when this happens. Free port 3001 (kill
whoever holds it) and re-install if you need the toggle to work today.

### Apple Silicon: ESP32 builds slow

Make sure you're on Docker Desktop (Apple Silicon build) or OrbStack — both
run native arm64. The compile-api image is multi-arch; you should not need
x86 emulation.

---

## Related docs

- DigiCode user docs (5 languages):
  `https://code.fablab-westharima.jp/docs/local-compile-server`
- DigiCode source repo (private): `fablab-westharima/digicode`
- Compile-api source: same repo, `compile-api/`
- Plan doc: `prompt/maintenance/46_2026-05-01_ローカルコンパイルInstaller計画.md`
