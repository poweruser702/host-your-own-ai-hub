#!/usr/bin/env bash
# Host-your-own AI hub — uninstall helper
# Stops the compose stack under AI_HUB_DIR and optionally removes data.
# Does NOT uninstall Docker or Tailscale (those may be shared).
# Does NOT revoke your Tailscale node — do that in the admin console if desired.
#
# Usage:
#   sudo bash uninstall.sh
#   sudo bash uninstall.sh --purge     # also remove /opt/ai-hub and named volumes
#   sudo bash uninstall.sh --dry-run
#
# Env:
#   AI_HUB_DIR   Install dir (default: /opt/ai-hub)

set -euo pipefail

AI_HUB_DIR="${AI_HUB_DIR:-/opt/ai-hub}"
DRY_RUN=0
PURGE=0

usage() {
  cat <<EOF
Usage: sudo bash uninstall.sh [--dry-run] [--purge]

  --dry-run   Print planned actions only
  --purge     Also delete $AI_HUB_DIR and Docker volumes created by this stack
  --help      Show help

Leaves Docker Engine and Tailscale installed.
EOF
}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --purge) PURGE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 && "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Run as root (sudo), or pass --dry-run."
fi

if [[ ! -d "$AI_HUB_DIR" ]]; then
  log "No directory at $AI_HUB_DIR — nothing to stop."
else
  if [[ -f "$AI_HUB_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    log "Stopping compose stack in $AI_HUB_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] docker compose -f %s/docker-compose.yml --profile webui down\n' "$AI_HUB_DIR"
    else
      # --profile webui so a profiled UI container is included if present
      (cd "$AI_HUB_DIR" && docker compose --profile webui down) || \
        (cd "$AI_HUB_DIR" && docker compose down) || true
    fi
  else
    log "No compose file or no docker — skip compose down."
  fi
fi

if [[ "$PURGE" -eq 1 ]]; then
  log "Purge requested."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] docker volume rm litellm_postgres_data (if exists)\n'
    printf '[dry-run] rm -rf %s\n' "$AI_HUB_DIR"
  else
    docker volume rm litellm_postgres_data 2>/dev/null || true
    # open-webui volume name is project-prefixed; best-effort remove dangling
    docker volume ls -q | while read -r v; do
      case "$v" in
        *open-webui-data*) docker volume rm "$v" 2>/dev/null || true ;;
      esac
    done
    rm -rf "$AI_HUB_DIR"
    log "Removed $AI_HUB_DIR"
  fi
else
  log "Left $AI_HUB_DIR in place (pass --purge to delete secrets + config)."
fi

log "Done. Docker and Tailscale were not uninstalled."
