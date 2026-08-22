#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Reset the demo between runs:
#   1. docker compose down -v  -> wipes ALL GitLab state (repos, users, tokens,
#      runners, pipeline history) and the runner config volume.
#   2. Optionally resets the working tree via the repo's existing
#      reset-to-branch.sh (interactive; resets to 'main' or the pristine
#      'original' branch).
#   3. With --up, brings the stack back and re-runs bootstrap.
#
# Usage: ./reset.sh [--tree [main|original]] [--up]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

reset_tree=false
tree_target="main"
re_up=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)
      reset_tree=true
      if [ "${2:-}" = "main" ] || [ "${2:-}" = "original" ]; then
        tree_target="$2"
        shift
      fi
      ;;
    --up) re_up=true ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

echo "[reset] Wiping GitLab stack and ALL its state (volumes)..."
docker compose -f "${SCRIPT_DIR}/docker-compose.gitlab.yml" down -v
git -C "${REPO_DIR}" remote remove gitlab 2>/dev/null || true
echo "[reset] GitLab state wiped. Local git clone untouched."

if [ "${reset_tree}" = true ]; then
  # Reuse the repo's existing reset script rather than duplicating its logic.
  echo "[reset] Resetting working tree via reset-to-branch.sh ${tree_target}..."
  (cd "${REPO_DIR}" && ./reset-to-branch.sh "${tree_target}")
fi

if [ "${re_up}" = true ]; then
  "${SCRIPT_DIR}/up.sh"
else
  echo "[reset] Done. Run ./up.sh to start a fresh demo."
fi
