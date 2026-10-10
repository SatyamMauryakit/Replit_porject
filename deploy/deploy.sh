#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/developer-portfolio"
STATE_DIR="/var/lib/developer-portfolio"
COMPOSE_FILE="$APP_DIR/compose.yaml"
NGINX_UPSTREAM_FILE="/etc/nginx/snippets/developer-portfolio-upstream.conf"
LOG_FILE="/var/log/developer-portfolio-deploy.log"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "Run this command through sudo."
}

validate_image() {
  local image="$1"
  [[ "$image" =~ ^[a-z0-9._-]+/[a-z0-9][a-z0-9._-]*$ ]] ||
    fail "Invalid Docker Hub image base. Expected namespace/repository."
}

port_for_slot() {
  case "$1" in
    blue) printf '18080' ;;
    green) printf '18081' ;;
    *) fail "Invalid deployment slot: $1" ;;
  esac
}

run_compose() {
  local slot="$1"
  local port="$2"
  local tag="$3"
  local image="$4"
  shift 4

  DOCKERHUB_IMAGE="$image" \
    DEPLOY_IMAGE_TAG="$tag" \
    WEB_HOST_PORT="$port" \
    docker compose \
      --env-file /dev/null \
      --project-name "developer-portfolio-$slot" \
      --file "$COMPOSE_FILE" \
      "$@"
}

write_state() {
  local filename="$1"
  local value="$2"
  local temporary="$STATE_DIR/.$filename.$$"
  printf '%s\n' "$value" > "$temporary"
  chmod 0644 "$temporary"
  mv "$temporary" "$STATE_DIR/$filename"
}

wait_for_release() {
  local port="$1"
  local attempts=45
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --fail --silent --show-error --max-time 3 \
      "http://127.0.0.1:$port/api/healthz" |
      grep --quiet --extended-regexp '"status"[[:space:]]*:[[:space:]]*"ok"' &&
      curl --fail --silent --show-error --max-time 3 \
        --output /dev/null "http://127.0.0.1:$port/"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

switch_nginx_upstream() {
  local port="$1"
  local temporary="$NGINX_UPSTREAM_FILE.$$"
  local backup="$NGINX_UPSTREAM_FILE.backup.$$"

  [[ -f "$NGINX_UPSTREAM_FILE" ]] ||
    fail "Nginx upstream include is missing: $NGINX_UPSTREAM_FILE"

  cp --preserve=mode,ownership "$NGINX_UPSTREAM_FILE" "$backup"
  printf 'proxy_pass http://127.0.0.1:%s;\n' "$port" > "$temporary"
  chmod --reference="$NGINX_UPSTREAM_FILE" "$temporary"
  chown --reference="$NGINX_UPSTREAM_FILE" "$temporary"
  mv "$temporary" "$NGINX_UPSTREAM_FILE"

  if nginx -t && systemctl reload nginx; then
    rm -f "$backup"
    return 0
  fi

  mv "$backup" "$NGINX_UPSTREAM_FILE"
  nginx -t && systemctl reload nginx || true
  return 1
}

restore_slot() {
  local slot="$1"
  local port="$2"
  local old_tag="$3"
  local image="$4"
  local failed_tag="$5"

  log "Restoring the inactive $slot slot after an unsuccessful release."
  if [[ -n "$old_tag" ]]; then
    run_compose "$slot" "$port" "$old_tag" "$image" \
      up --detach --no-build --wait --wait-timeout 90 || true
  else
    run_compose "$slot" "$port" "$failed_tag" "$image" \
      down --remove-orphans || true
  fi
}

cleanup_old_image_tags() {
  local image="$1"
  local active_tag="$2"
  local previous_tag="$3"
  local suffix repository tag

  for suffix in api web; do
    repository="${image}-${suffix}"
    while IFS= read -r tag; do
      [[ "$tag" =~ ^[a-f0-9]{40}$ ]] || continue
      [[ "$tag" == "$active_tag" || "$tag" == "$previous_tag" ]] && continue
      if docker image rm "${repository}:${tag}" >/dev/null 2>&1; then
        log "Removed unused local image tag ${repository}:${tag}."
      else
        log "Kept ${repository}:${tag}; Docker still reports it in use."
      fi
    done < <(docker image ls --format '{{.Tag}}' "$repository" | sort -u)
  done
}

deploy_release() {
  local tag="$1"
  local image="$2"
  local active_slot=""
  local active_tag=""
  local target_slot
  local target_port
  local old_target_tag=""

  [[ "$tag" =~ ^[a-f0-9]{40}$ ]] ||
    fail "Release tag must be a 40-character lowercase Git commit SHA."

  if [[ -f "$STATE_DIR/active-slot" ]]; then
    active_slot="$(cat "$STATE_DIR/active-slot")"
    [[ "$active_slot" == "blue" || "$active_slot" == "green" ]] ||
      fail "The saved active-slot state is invalid."
    active_tag="$(cat "$STATE_DIR/slot-${active_slot}.tag" 2>/dev/null || true)"
  fi

  if [[ "$active_slot" == "blue" ]]; then
    target_slot="green"
  else
    target_slot="blue"
  fi

  target_port="$(port_for_slot "$target_slot")"
  old_target_tag="$(cat "$STATE_DIR/slot-${target_slot}.tag" 2>/dev/null || true)"

  log "Preparing release $tag in the inactive $target_slot slot on port $target_port."
  run_compose "$target_slot" "$target_port" "$tag" "$image" pull ||
    fail "Could not pull the requested release from Docker Hub."

  if ! run_compose "$target_slot" "$target_port" "$tag" "$image" \
    up --detach --no-build --wait --wait-timeout 120; then
    run_compose "$target_slot" "$target_port" "$tag" "$image" logs --tail 80 || true
    restore_slot "$target_slot" "$target_port" "$old_target_tag" "$image" "$tag"
    fail "The new containers did not become healthy; production was not switched."
  fi

  if ! wait_for_release "$target_port"; then
    run_compose "$target_slot" "$target_port" "$tag" "$image" logs --tail 80 || true
    restore_slot "$target_slot" "$target_port" "$old_target_tag" "$image" "$tag"
    fail "The release failed its HTTP checks; production was not switched."
  fi

  if ! switch_nginx_upstream "$target_port"; then
    restore_slot "$target_slot" "$target_port" "$old_target_tag" "$image" "$tag"
    fail "Nginx could not switch to the new release; the previous route was restored."
  fi

  write_state "slot-${target_slot}.tag" "$tag"
  write_state "active-slot" "$target_slot"
  if [[ -n "$active_slot" ]]; then
    write_state "previous-slot" "$active_slot"
  else
    rm -f "$STATE_DIR/previous-slot"
  fi

  log "Release $tag is active in the $target_slot slot."
  cleanup_old_image_tags "$image" "$tag" "$active_tag"
}

rollback_release() {
  local image="$1"
  local active_slot
  local previous_slot
  local previous_tag
  local previous_port

  [[ -f "$STATE_DIR/active-slot" && -f "$STATE_DIR/previous-slot" ]] ||
    fail "There is no previous healthy release to roll back to."

  active_slot="$(cat "$STATE_DIR/active-slot")"
  previous_slot="$(cat "$STATE_DIR/previous-slot")"
  [[ "$active_slot" == "blue" || "$active_slot" == "green" ]] ||
    fail "The saved active-slot state is invalid."
  [[ "$previous_slot" == "blue" || "$previous_slot" == "green" ]] ||
    fail "The saved previous-slot state is invalid."

  previous_tag="$(cat "$STATE_DIR/slot-${previous_slot}.tag" 2>/dev/null || true)"
  [[ "$previous_tag" =~ ^[a-f0-9]{40}$ ]] ||
    fail "The previous release tag is missing or invalid."
  previous_port="$(port_for_slot "$previous_slot")"

  log "Checking previous release $previous_tag before rollback."
  wait_for_release "$previous_port" ||
    fail "The previous release is not healthy; the active release was left unchanged."

  switch_nginx_upstream "$previous_port" ||
    fail "Nginx could not switch to the previous release."

  write_state "active-slot" "$previous_slot"
  write_state "previous-slot" "$active_slot"
  log "Rolled back from the $active_slot slot to the $previous_slot slot ($previous_tag)."
}

main() {
  require_root
  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"
  [[ -d "$STATE_DIR" ]] || install -d -o root -g root -m 0755 "$STATE_DIR"

  case "${1:-}" in
    deploy)
      [[ "$#" -eq 3 ]] || fail "Usage: $0 deploy <40-character-commit-sha> <dockerhub-namespace/repository>"
      validate_image "$3"
      deploy_release "$2" "$3"
      ;;
    rollback)
      [[ "$#" -eq 2 ]] || fail "Usage: $0 rollback <dockerhub-namespace/repository>"
      validate_image "$2"
      rollback_release "$2"
      ;;
    *)
      fail "Usage: $0 {deploy <40-character-commit-sha> <namespace/repository>|rollback <namespace/repository>}"
      ;;
  esac
}

main "$@"
