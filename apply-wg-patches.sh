#!/usr/bin/env bash
# Apply our downstream patches on top of upstream wanderers-guide main.
# Usage: apply-wg-patches.sh [repo_dir]   (default ~/wanderers-guide)
# Builds a local "deployed" branch = origin/main + patches/*/*.patch, in folder order.
set -euo pipefail
REPO="${1:-$HOME/wanderers-guide}"
PATCHES="$(cd "$(dirname "$0")" && pwd)/patches"
cd "$REPO"
git fetch origin
git checkout -B deployed origin/main
for dir in "$PATCHES"/*/; do
  echo "== applying $(basename "$dir")"
  git am --3way "$dir"*.patch || { echo "Patch set $(basename "$dir") failed; upstream may have fixed it. Running git am --abort."; git am --abort; exit 1; }
done
echo "deployed = origin/main + $(ls -d "$PATCHES"/*/ | wc -l) patch sets"