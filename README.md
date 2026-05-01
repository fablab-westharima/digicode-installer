# DigiCode local compile-server installer

One-command installer for the DigiCode local compile-server
(`ghcr.io/fablab-westharima/digicode-compile-api:latest`).

> **Public mirror** of `fablab-westharima/digicode/scripts/local-compile/`
> (the upstream lives in the private DigiCode monorepo).

License: MIT — see [LICENSE](./LICENSE).

---

## Quick install

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/fablab-westharima/digicode-installer/main/install.ps1 | iex
```

That's it. The script:

1. Checks Docker is installed (prints OS-specific download URL if not, then exits)
2. Checks Docker daemon is running
3. Writes `~/.digicode/compile-server/docker-compose.yml`
4. Pulls `ghcr.io/fablab-westharima/digicode-compile-api:latest` (~1 GB compressed)
5. Starts the container on `localhost:3001` with persistent named volumes
6. Verifies `http://localhost:3001/health` returns `{"status":"ok"}`
7. Prints the next step (toggle DigiCode → 「ローカルサーバー」)

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
bash install.sh [subcommand]
# or on Windows:
.\install.ps1 [subcommand]
```

| Subcommand     | Action                                                                     |
| -------------- | -------------------------------------------------------------------------- |
| `install`      | (default) pull image, start container, wait for `/health` to come up       |
| `update`       | pull latest image and recreate the container                               |
| `uninstall`    | stop + remove container, delete volumes and install dir (asks for image)   |
| `status`       | show container state, image, and a live health check                       |
| `start`        | start an existing (stopped) container                                      |
| `stop`         | stop the container without removing it                                     |
| `help`         | show built-in usage                                                        |

### Examples

```bash
bash install.sh             # first-time install
bash install.sh status      # is it running and healthy?
bash install.sh update      # pull a new image and restart
bash install.sh stop        # stop without losing the cache
bash install.sh start       # bring it back up
bash install.sh uninstall   # nuke everything (asks twice)
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

Some other app holds 3001. Either stop it, or temporarily edit the generated
`~/.digicode/compile-server/docker-compose.yml` to map a different host port:

```yaml
ports:
  - "3002:3001"
```

…then run `bash install.sh start`. (Note: DigiCode's "ローカルサーバー" toggle
hard-codes port 3001 today; pointing it elsewhere is a planned follow-up.)

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
