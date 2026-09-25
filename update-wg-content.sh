#!/usr/bin/env bash
# Catch-up: swap official book content (spells, sources, etc.) since last apply.
# Does not drop public. User/character/homebrew rows are kept. Failed apply restores a pg_dump.
#
#   ./scripts/linux/update-wg-content.sh --src /opt/wanderers-guide
#   ./scripts/linux/update-wg-content.sh --src /opt/wanderers-guide --yes
#   ./scripts/linux/update-wg-content.sh --src /opt/wanderers-guide --force
#   ./scripts/linux/update-wg-content.sh --src /opt/wanderers-guide --since 2026-08-02
#   ./scripts/linux/update-wg-content.sh --src /opt/wanderers-guide --repair-grants
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wg-update-common.sh
source "$HERE/wg-update-common.sh"

# Content commit iteration redirects stdin to the commit list. Always read
# interactive confirmations from the controlling terminal so a prompt inside
# that loop cannot consume EOF and terminate the script under set -e.
pause_check() {
  local debug="$1" prompt="$2" skip="${3:-0}"
  if [[ "$skip" == "1" ]]; then
    debug_log "$debug" "pause skipped: $prompt"
    return 0
  fi
  printf '\n'
  printf '%s\n' "$prompt"
  debug_log "$debug" "pause: $prompt"
  read -r -p "Press Enter to continue, or Ctrl+C to abort " </dev/tty
}

SRC="${WG_SRC:-}"
FORCE=0
SINCE=""
YES=0
REPAIR_GRANTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --repair-grants) REPAIR_GRANTS=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SRC" ]]; then
  SRC="$(amba_root)/scripts/_wg-src"
fi

if [[ "$REPAIR_GRANTS" == "1" ]]; then
  repair_wg_grants "$SRC"
  exit $?
fi

run_wg_update "$SRC" content "$FORCE" "$SINCE" "$YES"
