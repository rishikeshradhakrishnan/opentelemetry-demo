#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap the local GitLab instance for the AI-native SDLC demo:
#   1. Wait for GitLab to be healthy (cold start is 3-5+ minutes).
#   2. Create a root personal access token (via gitlab-rails runner).
#   3. Create the "demo" group and "demo/opentelemetry-demo" project.
#   4. Push this repo (main + the demo branch) into the local GitLab project.
#   5. Create + register a docker-executor runner (GitLab 16+ token flow).
#   6. Wire CI/CD variables: GITLAB_TOKEN (project token) and, if present in
#      your shell, ANTHROPIC_API_KEY. No secret is ever written to the repo.
#
# Idempotency: safe to re-run; existing group/project/runner registrations are
# reused or recreated where the API allows it.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env)
# ---------------------------------------------------------------------------
GITLAB_URL="${GITLAB_URL:-http://localhost:8929}"
GITLAB_CONTAINER="${GITLAB_CONTAINER:-gitlab}"
RUNNER_CONTAINER="${RUNNER_CONTAINER:-gitlab-runner}"
# URL as seen from inside the docker network (runner + CI job containers).
GITLAB_INTERNAL_URL="${GITLAB_INTERNAL_URL:-http://gitlab:8929}"
DOCKER_NETWORK="${DOCKER_NETWORK:-gitlab}"
GROUP_PATH="${GROUP_PATH:-demo}"
PROJECT_PATH="${PROJECT_PATH:-opentelemetry-demo}"
DEMO_BRANCH="${DEMO_BRANCH:-demo/gitlab-ai-sdlc}"
WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-900}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker  >/dev/null || die "docker CLI not found"
command -v curl    >/dev/null || die "curl not found"
command -v git     >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found (used for JSON parsing)"

# jq-lite: read a dotted path out of JSON on stdin, e.g. json_get id
json_get() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
for key in sys.argv[1:]:
    data = data[int(key)] if isinstance(data, list) else data[key]
print(data)
' "$@"
}

api() { # api METHOD PATH [curl-data-args...]
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    "$@" \
    "${GITLAB_URL}/api/v4${path}"
}

# ---------------------------------------------------------------------------
# 1. Wait for GitLab readiness
# ---------------------------------------------------------------------------
log "Waiting for GitLab at ${GITLAB_URL} (cold start takes 3-5+ minutes;"
log "timeout ${WAIT_TIMEOUT_SECS}s)..."
elapsed=0
until curl -fsS "${GITLAB_URL}/-/readiness" >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$WAIT_TIMEOUT_SECS" ]; then
    die "GitLab did not become ready in ${WAIT_TIMEOUT_SECS}s. Check: docker logs ${GITLAB_CONTAINER}"
  fi
  printf '  ... still booting (%ss elapsed)\r' "$elapsed"
  sleep 10
  elapsed=$((elapsed + 10))
done
printf '\n'
log "GitLab is ready."

# ---------------------------------------------------------------------------
# 2. Root API token (gitlab-rails runner: reliable and non-interactive)
# ---------------------------------------------------------------------------
# PATs must be >=20 chars. Generated fresh each run, never persisted to disk
# except in this shell and (see step 4) the local git remote URL.
ROOT_TOKEN="glpat-demo-$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)"

log "Creating root personal access token (docker exec gitlab-rails runner)..."
docker exec "${GITLAB_CONTAINER}" gitlab-rails runner "
  user = User.find_by_username('root')
  user.personal_access_tokens.where(name: 'ai-sdlc-demo-bootstrap').each(&:revoke!)
  token = user.personal_access_tokens.create!(
    name: 'ai-sdlc-demo-bootstrap',
    scopes: [:api, :create_runner, :write_repository],
    expires_at: 30.days.from_now
  )
  token.set_token('${ROOT_TOKEN}')
  token.save!
" || die "Failed to create root token. Is the '${GITLAB_CONTAINER}' container running?"
log "Root token created (scopes: api, create_runner, write_repository)."

# ---------------------------------------------------------------------------
# 3. Group + project
# ---------------------------------------------------------------------------
log "Ensuring group '${GROUP_PATH}' exists..."
if group_json="$(api GET "/groups/${GROUP_PATH}" 2>/dev/null)"; then
  group_id="$(printf '%s' "$group_json" | json_get id)"
  log "Group exists (id ${group_id})."
else
  group_json="$(api POST /groups \
    --data-urlencode "name=${GROUP_PATH}" \
    --data-urlencode "path=${GROUP_PATH}" \
    --data-urlencode "visibility=private")"
  group_id="$(printf '%s' "$group_json" | json_get id)"
  log "Group created (id ${group_id})."
fi

proj_encoded="${GROUP_PATH}%2F${PROJECT_PATH}"
log "Ensuring project '${GROUP_PATH}/${PROJECT_PATH}' exists..."
if proj_json="$(api GET "/projects/${proj_encoded}" 2>/dev/null)"; then
  project_id="$(printf '%s' "$proj_json" | json_get id)"
  log "Project exists (id ${project_id})."
else
  proj_json="$(api POST /projects \
    --data-urlencode "name=${PROJECT_PATH}" \
    --data-urlencode "path=${PROJECT_PATH}" \
    --data-urlencode "namespace_id=${group_id}" \
    --data-urlencode "visibility=private" \
    --data-urlencode "initialize_with_readme=false")"
  project_id="$(printf '%s' "$proj_json" | json_get id)"
  log "Project created (id ${project_id})."
fi

# ---------------------------------------------------------------------------
# 4. Push the demo code into local GitLab
# ---------------------------------------------------------------------------
# The token is embedded in the remote URL and therefore stored in .git/config
# of YOUR LOCAL CLONE ONLY (demo-only credential, 30-day expiry). Remove with:
#   git remote remove gitlab
push_url="http://root:${ROOT_TOKEN}@${GITLAB_URL#http://}/${GROUP_PATH}/${PROJECT_PATH}.git"
log "Pushing code to local GitLab project..."
git -C "${REPO_DIR}" remote remove gitlab 2>/dev/null || true
git -C "${REPO_DIR}" remote add gitlab "${push_url}"
git -C "${REPO_DIR}" push gitlab "main:main" 2>/dev/null \
  || warn "Could not push 'main' (not present locally? shallow clone?). Continuing."
git -C "${REPO_DIR}" push gitlab "${DEMO_BRANCH}:${DEMO_BRANCH}" \
  || die "Failed to push '${DEMO_BRANCH}'. Are you on the demo branch clone?"
log "Code pushed (main + ${DEMO_BRANCH})."

# Make the demo branch the default so its .gitlab-ci.yml drives pipelines and
# MRs target it by default.
api PUT "/projects/${project_id}" \
  --data-urlencode "default_branch=${DEMO_BRANCH}" >/dev/null
log "Default branch set to ${DEMO_BRANCH}."

# ---------------------------------------------------------------------------
# 5. Runner: create (GitLab 16+ authentication-token flow) + register
# ---------------------------------------------------------------------------
# POST /user/runners returns a runner authentication token (glrt-...). This
# replaces the deprecated registration-token flow.
log "Creating instance runner via POST /api/v4/user/runners..."
runner_json="$(api POST /user/runners \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=ai-sdlc-demo docker runner" \
  --data-urlencode "run_untagged=true" \
  --data-urlencode "tag_list=docker,demo")"
runner_token="$(printf '%s' "$runner_json" | json_get token)"
log "Runner created (id $(printf '%s' "$runner_json" | json_get id))."

log "Registering runner in the ${RUNNER_CONTAINER} container (docker executor)..."
docker exec "${RUNNER_CONTAINER}" gitlab-runner register \
  --non-interactive \
  --url "${GITLAB_INTERNAL_URL}" \
  --token "${runner_token}" \
  --executor docker \
  --docker-image "docker:27" \
  --docker-network-mode "${DOCKER_NETWORK}" \
  --clone-url "${GITLAB_INTERNAL_URL}" \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --docker-pull-policy if-not-present
log "Runner registered: docker executor, default image docker:27, network ${DOCKER_NETWORK}."
log "  (docker.sock is mounted into jobs so the build stage can docker-build.)"

# ---------------------------------------------------------------------------
# 6. CI/CD variables
# ---------------------------------------------------------------------------
set_ci_variable() { # key value masked(true/false)
  local key="$1" value="$2" masked="$3"
  api DELETE "/projects/${project_id}/variables/${key}" >/dev/null 2>&1 || true
  api POST "/projects/${project_id}/variables" \
    --data-urlencode "key=${key}" \
    --data-urlencode "value=${value}" \
    --data-urlencode "masked=${masked}" \
    --data-urlencode "protected=false" >/dev/null
}

# GITLAB_TOKEN: project access token used by CI jobs to post MR notes and
# push AI fix branches. Created via the API, stored only as a CI/CD variable.
log "Creating project access token for CI (GITLAB_TOKEN variable)..."
pat_json="$(api POST "/projects/${project_id}/access_tokens" \
  --data-urlencode "name=ai-sdlc-demo-ci" \
  --data-urlencode "scopes[]=api" \
  --data-urlencode "scopes[]=write_repository" \
  --data-urlencode "access_level=40" \
  --data-urlencode "expires_at=$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)")"
project_token="$(printf '%s' "$pat_json" | json_get token)"
set_ci_variable "GITLAB_TOKEN" "${project_token}" "true"
log "GITLAB_TOKEN CI/CD variable set (masked)."

# ANTHROPIC_API_KEY: only if the operator exported it. NEVER stored in-repo.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  set_ci_variable "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY}" "true"
  log "ANTHROPIC_API_KEY CI/CD variable set from your shell (masked)."
else
  warn "ANTHROPIC_API_KEY is not set in your shell."
  warn "The claude-review / claude-autofix jobs need it. Set it in the GitLab UI:"
  warn "  ${GITLAB_URL}/${GROUP_PATH}/${PROJECT_PATH}/-/settings/ci_cd"
  warn "  -> Variables -> Add variable -> key ANTHROPIC_API_KEY (masked)."
fi

# ---------------------------------------------------------------------------
log ""
log "Bootstrap complete."
log "  Web UI:    ${GITLAB_URL}  (user: root / password: \$GITLAB_ROOT_PASSWORD, default demopassword123!)"
log "  Project:   ${GITLAB_URL}/${GROUP_PATH}/${PROJECT_PATH}"
log "  Pipelines: ${GITLAB_URL}/${GROUP_PATH}/${PROJECT_PATH}/-/pipelines"
log "Open an MR against '${DEMO_BRANCH}' to see the AI-review pipeline in action."
