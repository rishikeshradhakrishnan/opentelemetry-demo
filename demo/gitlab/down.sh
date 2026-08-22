#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Stop the GitLab demo stack. State (repos, users, runner config) is KEPT in
# the named volumes; use ./reset.sh to wipe it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker compose -f "${SCRIPT_DIR}/docker-compose.gitlab.yml" down
echo "[down] Stack stopped. Volumes kept — './up.sh --no-bootstrap' resumes with state intact."
