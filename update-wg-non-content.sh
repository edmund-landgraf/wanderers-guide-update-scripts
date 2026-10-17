#!/usr/bin/env bash
# Catch-up: rebuild WG frontend for non-dump commits since last apply or compose date.
#
# Production (vps-ahhh): ~/wg-update-scripts/update-wg-non-content.sh --src ~/wanderers-guide
#   ./update-wg-non-content.sh --src "$HOME/wanderers-guide" --force
#   ./update-wg-non-content.sh --src "$HOME/wanderers-guide" --yes
#   ./update-wg-non-content.sh --src "$HOME/wanderers-guide" --since 2026-08-02
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wg-update-common.sh
source "$HERE/wg-update-common.sh"

SRC="${WG_SRC:-}"
FORCE=0
SINCE=""
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--src requires a path" >&2; exit 2; }
      SRC="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --since)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--since requires a date or commit SHA" >&2; exit 2; }
      SINCE="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SRC" ]]; then
  SRC="$(default_wg_src)"
fi

run_wg_update "$SRC" non-content "$FORCE" "$SINCE" "$YES"
