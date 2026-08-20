# Wanderer's Guide Update Scripts

Maintenance helpers for self-hosted [Wanderer's Guide](https://github.com/wanderers-guide/wanderers-guide) installations.

The scripts are intended to separate **official content updates** from **application/code updates**, so a self-hosted instance can refresh Pathfinder/Wanderer's Guide content without replacing user, character, or homebrew data.

## Scripts

- `update-wg-content.sh` — applies official-content updates and catches up from the last successfully applied state. Supports an optional `--since` override.
- `update-wg-non-content.sh` — updates non-content/application changes. *(Add the companion script from your deployment.)*
- `wg-update-common.sh` — shared update, state, backup, Git, and database helper functions. *(Required by the update wrappers.)*
- `wg-reload-official-content.sh` — performs the protected official-content reload while preserving user-owned data. *(Required for content updates.)*

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

Once `update-wg-non-content.sh` and `wg-update-common.sh` are present:

```bash
WG_UPDATE_LOG_DIR="$HOME/logs/wg-update" \
  ~/wg-update-scripts/update-wg-non-content.sh \
  --src "$HOME/wanderers-guide" \
  --yes
```

Application/code updates may require rebuilding or restarting the Wanderer's Guide Docker stack depending on what changed.

A typical rebuild is:

```bash
cd ~/wanderers-guide
docker compose up -d --build
docker compose ps
```

Content-only database updates normally do not require a restart.

## Cron example

Example daily official-content update at 03:15 server time:

```cron
SHELL=/bin/bash
HOME=/home/YOUR_USER
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 3 * * * /usr/bin/flock -n /tmp/wg-content-update.lock /bin/bash -lc 'export WG_UPDATE_LOG_DIR="$HOME/logs/wg-update"; "$HOME/wg-update-scripts/update-wg-content.sh" --src "$HOME/wanderers-guide" --yes' >> "$HOME/logs/wg-update/cron-content.log" 2>&1
```

Create the log directory first:

```bash
mkdir -p "$HOME/logs/wg-update"
```

## Safety

These scripts modify a live self-hosted Wanderer's Guide installation and database. Review them before use and keep tested database backups.

Do not substitute a destructive full database initialization for the protected official-content reload unless you explicitly intend to recreate the database.

## Current repository status

The public repository currently contains the exact `update-wg-content.sh` wrapper from the working deployment. The companion `update-wg-non-content.sh`, `wg-update-common.sh`, and `wg-reload-official-content.sh` should be copied from the working server before this package is considered complete.
