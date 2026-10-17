# Wanderer's Guide Update Scripts

Maintenance helpers for self-hosted [Wanderer's Guide](https://github.com/wanderers-guide/wanderers-guide) installations.

The scripts are intended to separate **official content updates** from **application/code updates**, so a self-hosted instance can refresh Pathfinder/Wanderer's Guide content without replacing user, character, or homebrew data.

## Scripts

- `update-wg-content.sh` — swaps official catalog rows when `data/schema.sql` or `data/data.sql` changes. Does not apply `supabase/migrations/`.
- `update-wg-non-content.sh` — fast-forwards non-dump commits, applies any new `supabase/migrations/*.sql` since the last successful content swap, then rebuilds **only** the `frontend` service.
- `update-wg-migrations.sh` — applies those SQL files without rebuilding the frontend.
- `wg-update-common.sh` — shared update, state, backup, Git, and database helper functions.
- `wg-reload-official-content.sh` — swaps official catalog rows only (does not drop `public`). After a committed swap it will not restore the pre-apply dump or `git reset` to the old SHA.

## Where this repo lives

| Place | Path |
| --- | --- |
| Edit / git on Windows | `D:\repos\edmund-landgraf\wanderers-guide-update-scripts` |
| Production (vps-ahhh) | `~/wg-update-scripts` (this clone) |
| WG Docker stack on vps-ahhh | `~/wanderers-guide` (pass as `--src`) |

The scripts repo and the Wanderer's Guide compose checkout are different directories. `--src` always points at the compose checkout.

## Installation on vps-ahhh

```bash
git clone https://github.com/edmund-landgraf/wanderers-guide-update-scripts.git ~/wg-update-scripts
cd ~/wg-update-scripts
chmod +x *.sh
```

If you omit `--src` and `WG_SRC`, the scripts use `../wanderers-guide` (sibling of this clone) or `~/wanderers-guide` when that directory is a git checkout with `docker-compose.yml`.

### Windows PowerShell (WSL bash)

`bash` from PowerShell is usually WSL, so `D:/repos/...` is not a path. Use `/mnt/d/...`, omit `--src` (sibling checkout), or rely on the scripts converting `D:/...` after you pull this change.

```powershell
cd D:\repos\edmund-landgraf\wanderers-guide-update-scripts
bash ./update-wg-content.sh --src /mnt/d/repos/edmund-landgraf/wanderers-guide --yes
bash ./update-wg-non-content.sh --src /mnt/d/repos/edmund-landgraf/wanderers-guide --yes
```

## Content update

```bash
WG_UPDATE_LOG_DIR="$HOME/logs/wg-update" \
  ~/wg-update-scripts/update-wg-content.sh \
  --src "$HOME/wanderers-guide" \
  --yes
```

The content updater is designed to:

1. determine the previously applied content state;
2. inspect/fetch newer upstream changes;
3. back up the PostgreSQL data before applying content changes;
4. reload official WG/PF2 content;
5. preserve users, characters, authentication, and homebrew/user-owned data;
6. record the newly applied state only after a successful update.

You can override the automatic catch-up point when necessary:

```bash
~/wg-update-scripts/update-wg-content.sh \
  --src "$HOME/wanderers-guide" \
  --since 2026-08-02
```

Other supported options include:

```text
--force
--yes / -y
--repair-grants
```

## Non-content update

```bash
WG_UPDATE_LOG_DIR="$HOME/logs/wg-update" \
  ~/wg-update-scripts/update-wg-non-content.sh \
  --src "$HOME/wanderers-guide" \
  --force
```

Application updates rebuild the frontend image only. The Experimental header link is `docker/experimental-nav.compose.yml`. A non-content run copies it to `docker-compose.override.yml` in the Wanderer's Guide checkout when that file is missing or is already this inject, and passes it as an extra `-f` on the frontend recreate. On localhost the link goes to `http://localhost:5194`. On any other host, including amba, it goes to `https://wgui.wandersguide.site`. A run with no new commits still installs the file; pass `--force` to recreate the container.

```bash
cd ~/wanderers-guide
docker compose up -d --build frontend
```

Do not run `docker compose up -d --build` with no service name on a host that injects WGUI edge functions. That recreates the `functions` service from the Wanderer's Guide compose file alone and drops the `wgui-ext` overlay. If `functions` was recreated, put the overlay back with:

```bash
cd ~/node-sites/WandersGuideUI
WG_DIR="$HOME/wanderers-guide" npm run stack:restart
```

Targeted SQL in `supabase/migrations/` (feat/creature repairs that are not in `data/data.sql`) is applied by `update-wg-non-content.sh` and by:

```bash
~/wg-update-scripts/update-wg-migrations.sh \
  --src "$HOME/wanderers-guide" \
  --yes
```

Pending files are those added or modified after the last successful content-update SHA, minus `~/logs/wg-update/applied-migrations.txt`. With no content history yet, the first run records the current migration files as already applied and does not replay them.

`git reset` / fast-forward keeps `skip-worktree` and `assume-unchanged` worktree files (local OAuth overlay). `.env` and untracked `docker-compose.override.yml` are also left in place.

Content-only database updates normally do not require a restart.

## Cron example

Official content at 03:15, code and migrations at 03:45:

```cron
SHELL=/bin/bash
HOME=/home/YOUR_USER
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 3 * * * /usr/bin/flock -n /tmp/wg-content-update.lock /bin/bash -lc 'export WG_UPDATE_LOG_DIR="$HOME/logs/wg-update"; "$HOME/wg-update-scripts/update-wg-content.sh" --src "$HOME/wanderers-guide" --yes' >> "$HOME/logs/wg-update/cron-content.log" 2>&1
45 3 * * * /usr/bin/flock -n /tmp/wg-non-content-update.lock /bin/bash -lc 'export WG_UPDATE_LOG_DIR="$HOME/logs/wg-update"; "$HOME/wg-update-scripts/update-wg-non-content.sh" --src "$HOME/wanderers-guide" --yes' >> "$HOME/logs/wg-update/cron-non-content.log" 2>&1
```

Create the log directory first:

```bash
mkdir -p "$HOME/logs/wg-update"
```

## Safety

These scripts modify a live self-hosted Wanderer's Guide installation and database. Review them before use and keep tested database backups.

Do not substitute a destructive full database initialization for the protected official-content reload unless you explicitly intend to recreate the database.

## Current repository status

This repository includes the four Linux scripts (`update-wg-content.sh`, `update-wg-non-content.sh`, `wg-update-common.sh`, `wg-reload-official-content.sh`). Push from Windows, pull on vps-ahhh into `~/wg-update-scripts`, then run against `~/wanderers-guide`. Logs default to `$HOME/logs/wg-update`.
