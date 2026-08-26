#!/usr/bin/env bash
# Catch-up: rebuild WG frontend for non-dump commits since last apply or compose date.
#
#   ./scripts/linux/update-wg-non-content.sh --src /opt/wanderers-guide
#   ./scripts/linux/update-wg-non-content.sh --src /opt/wanderers-guide --force
#   ./scripts/linux/update-wg-non-content.sh --src /opt/wanderers-guide --yes
#   ./scripts/linux/update-wg-non-content.sh --src /opt/wanderers-guide --since 2026-08-02
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
    --src) SRC="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SRC" ]]; then
  SRC="$(amba_root)/scripts/_wg-src"
fi

run_wg_update "$SRC" non-content "$FORCE" "$SINCE" "$YES"
