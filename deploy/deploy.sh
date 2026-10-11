#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${APP_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/compose.yaml}"
PROJECT_NAME="${PROJECT_NAME:-developer-portfolio}"
WEB_HEALTH_URL="${WEB_HEALTH_URL:-http://127.0.0.1:18080/}"
API_HEALTH_URL="${API_HEALTH_URL:-http://127.0.0.1:18080/api/healthz}"
RELEASE_DIR="${RELEASE_DIR:-$APP_DIR/.deploy-state}"
CURRENT_RELEASE_FILE="$RELEASE_DIR/current.env"
PREVIOUS_RELEASE_FILE="$RELEASE_DIR/previous.env"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

compose_cmd() {
  if docker info >/dev/null 2>&1; then
    docker compose "$@"
  elif sudo -n docker info >/dev/null 2>&1; then
    sudo docker compose "$@"
  else
    fail "Docker daemon is not accessible. Add this user to docker group or allow passwordless sudo for docker."
  fi
}

run_compose() {
  compose_cmd --project-name "$PROJECT_NAME" --file "$COMPOSE_FILE" "$@"
}

health_check() {
  command -v curl >/dev/null 2>&1 || fail "curl is required for health checks."

  curl --fail --silent --show-error --max-time 5 --output /dev/null "$WEB_HEALTH_URL"
  curl --fail --silent --show-error --max-time 5 "$API_HEALTH_URL" \
    | grep --quiet --extended-regexp '"status"[[:space:]]*:[[:space:]]*"ok"'
}

# Records which images are currently running so `rollback` can restore the
# prior release without needing network/registry access.
record_release() {
  mkdir -p "$RELEASE_DIR"
  if [[ -f "$CURRENT_RELEASE_FILE" ]]; then
    cp "$CURRENT_RELEASE_FILE" "$PREVIOUS_RELEASE_FILE"
  fi
  {
    printf 'API_IMAGE=%q\n' "$1"
    printf 'WEB_IMAGE=%q\n' "$2"
    printf 'DEPLOYED_AT=%q\n' "$(date --iso-8601=seconds)"
  } > "$CURRENT_RELEASE_FILE"
}

pull_deploy() {
  [[ -n "${API_IMAGE:-}" ]] || fail "API_IMAGE must be set (e.g. ghcr.io/owner/repo-api:sha-xxxx)."
  [[ -n "${WEB_IMAGE:-}" ]] || fail "WEB_IMAGE must be set (e.g. ghcr.io/owner/repo-web:sha-xxxx)."

  log "Pulling API_IMAGE=$API_IMAGE WEB_IMAGE=$WEB_IMAGE"
  run_compose pull
  log "Starting containers from pulled images (no rebuild)."
  run_compose up --detach --remove-orphans --wait
  health_check
  record_release "$API_IMAGE" "$WEB_IMAGE"
  log "Pull-based deployment is healthy."
}

rollback() {
  [[ -f "$PREVIOUS_RELEASE_FILE" ]] || fail "No previous release recorded in $PREVIOUS_RELEASE_FILE; nothing to roll back to."

  # shellcheck disable=SC1090
  source "$PREVIOUS_RELEASE_FILE"
  [[ -n "${API_IMAGE:-}" && -n "${WEB_IMAGE:-}" ]] || fail "Previous release file is incomplete."

  log "Rolling back to API_IMAGE=$API_IMAGE WEB_IMAGE=$WEB_IMAGE (deployed at ${DEPLOYED_AT:-unknown})."
  export API_IMAGE WEB_IMAGE
  # Intentionally no `pull` here: rollback must work even if the registry is
  # unreachable, using the image layers already cached locally from the
  # previous successful pull-deploy.
  run_compose up --detach --remove-orphans --wait
  health_check
  record_release "$API_IMAGE" "$WEB_IMAGE"
  log "Rollback complete and healthy."
}

main() {
  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"

  case "${1:-}" in
    deploy|up)
      log "Building and starting containers with Docker Compose."
      run_compose up --build --detach --remove-orphans --wait
      health_check
      log "Deployment is healthy."
      ;;
    pull-deploy)
      pull_deploy
      ;;
    rollback)
      rollback
      ;;
    restart)
      log "Restarting containers."
      run_compose up --detach --remove-orphans --wait
      health_check
      log "Containers restarted and healthy."
      ;;
    down|stop)
      run_compose down --remove-orphans
      ;;
    status|ps)
      run_compose ps
      ;;
    logs)
      if [[ -n "${2:-}" ]]; then
        run_compose logs --tail "${TAIL_LINES:-100}" "$2"
      else
        run_compose logs --tail "${TAIL_LINES:-100}"
      fi
      ;;
    health)
      health_check
      log "Health checks passed."
      ;;
    *)
      fail "Usage: $0 {deploy|up|pull-deploy|rollback|restart|down|stop|status|ps|logs [service]|health}"
      ;;
  esac
}

main "$@"
