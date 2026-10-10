#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${APP_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/compose.yaml}"
PROJECT_NAME="${PROJECT_NAME:-developer-portfolio}"
WEB_HEALTH_URL="${WEB_HEALTH_URL:-http://127.0.0.1:18080/}"
API_HEALTH_URL="${API_HEALTH_URL:-http://127.0.0.1:18080/api/healthz}"

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

main() {
  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"

  case "${1:-}" in
    deploy|up)
      log "Building and starting containers with Docker Compose."
      run_compose up --build --detach --remove-orphans --wait
      health_check
      log "Deployment is healthy."
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
      fail "Usage: $0 {deploy|up|restart|down|stop|status|ps|logs [service]|health}"
      ;;
  esac
}

main "$@"
