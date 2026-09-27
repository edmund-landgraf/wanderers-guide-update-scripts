# Wanderer's Guide Update Scripts

Maintenance helpers for self-hosted [Wanderer's Guide](https://github.com/wanderers-guide/wanderers-guide) installations.

The scripts are intended to separate **official content updates** from **application/code updates**, so a self-hosted instance can refresh Pathfinder/Wanderer's Guide content without replacing user, character, or homebrew data.

## Scripts

- `update-wg-content.sh` — swaps official catalog rows when `data/schema.sql` or `data/data.sql` changes. Does not apply `supabase/migrations/`.
- `update-wg-non-content.sh` — fast-forwards non-dump commits, applies any new `supabase/migrations/*.sql` since the last successful content swap, then rebuilds **only** the `frontend` service.
- `update-wg-migrations.sh` — applies those SQL files without rebuilding the frontend.
- `wg-update-common.sh` — shared update, state, backup, Git, and database helper functions.
- `wg-reload-official-content.sh` — swaps official catalog rows only (does not drop `public`). After a committed swap it will not restore the pre-apply dump or `git reset` to the old SHA.

## Installation

Clone this repository on the same Linux host as your Wanderer's Guide checkout:

```bash
git clone https://github.com/edmund-landgraf/wanderers-guide-update-scripts.git ~/wg-update-scripts
cd ~/wg-update-scripts
chmod +x *.sh
```

Assume Wanderer's Guide itself is installed at:

```text
~/wanderers-guide
```

You can use any location by supplying `--src`.

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

Application updates rebuild the frontend image only:

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

This repository includes the four Linux scripts (`update-wg-content.sh`, `update-wg-non-content.sh`, `wg-update-common.sh`, `wg-reload-official-content.sh`). On a host where Wanderer's Guide is at `/opt/wanderers-guide`, use `--src /opt/wanderers-guide`.
