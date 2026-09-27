#!/usr/bin/env bash
# Apply supabase/migrations/*.sql added since the last successful content swap.
# Does not reload data/data.sql and does not rebuild the frontend.
#
#   ./update-wg-migrations.sh --src /home/administrator/wanderers-guide --yes
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wg-update-common.sh
source "$HERE/wg-update-common.sh"

SRC="${WG_SRC:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --yes|-y) shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SRC" ]]; then
  echo "--src is required" >&2
  exit 2
fi
SRC="$(cd "$SRC" && pwd)"
assert_git_src "$SRC"
debug="$(init_log_dir)/debug-migrations.log"
: >"$debug"
apply_pending_migrations "$SRC" "$debug"
