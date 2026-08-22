#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# One-command bring-up: start GitLab + runner, then bootstrap everything.
# Usage: ./up.sh [--no-bootstrap]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.gitlab.yml"

echo "[up] Starting GitLab CE + runner (first boot takes 3-5+ minutes)..."
docker compose -f "${COMPOSE_FILE}" up -d

if [ "${1:-}" != "--no-bootstrap" ]; then
  "${SCRIPT_DIR}/bootstrap.sh"
else
  echo "[up] Skipping bootstrap (--no-bootstrap). Run ./bootstrap.sh when ready."
fi
