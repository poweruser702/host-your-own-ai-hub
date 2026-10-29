#!/usr/bin/env bash
# Host-your-own AI hub — one-command installer (copy-first)
# Upstream guide: https://github.com/poweruser702/host-your-own-ai-hub
#
# Safer path (recommended): download, read, then run.
#   curl -fsSL https://raw.githubusercontent.com/poweruser702/host-your-own-ai-hub/main/install.sh -o install.sh
#   less install.sh
#   sudo bash install.sh
#
# Flags:
#   --dry-run     Print planned actions; write nothing durable; do not install packages
#   --lockdown    After install, apply UFW: deny incoming, allow on tailscale0
#   --skip-webui  (default) Keep Open WebUI profile off; pass --with-webui to enable
#   --with-webui  Start the optional Open WebUI service
#   --help        Show usage
#
# Env (optional):
#   TS_AUTHKEY            Tailscale auth key (no default; prompted if missing)
#   OPENROUTER_API_KEY    OpenRouter key (prompted with hidden input if missing)
#   AI_HUB_DIR            Install dir (default: /opt/ai-hub)
#   AI_HUB_REPO_RAW       Raw GitHub base for compose/config files
#   AI_HUB_LOCAL_DIR      If set, copy compose/config from this local directory instead of curling
#   AI_HUB_HOSTNAME       Tailscale hostname (default: ai-hub)
#   AI_HUB_HEALTH_RETRIES Health poll attempts (default: 60; ~2s each)
#
# Redaction: this script contains no real IPs, keys, emails, or entity names.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_RAW_DEFAULT="https://raw.githubusercontent.com/poweruser702/host-your-own-ai-hub/main"
AI_HUB_REPO_RAW="${AI_HUB_REPO_RAW:-$REPO_RAW_DEFAULT}"
AI_HUB_DIR="${AI_HUB_DIR:-/opt/ai-hub}"
AI_HUB_HOSTNAME="${AI_HUB_HOSTNAME:-ai-hub}"
AI_HUB_LOCAL_DIR="${AI_HUB_LOCAL_DIR:-}"
AI_HUB_HEALTH_RETRIES="${AI_HUB_HEALTH_RETRIES:-60}"

DRY_RUN=0
LOCKDOWN=0
WITH_WEBUI=0

usage() {
  cat <<EOF
Usage: sudo bash $SCRIPT_NAME [options]

Installs Docker Engine + Compose plugin, Tailscale, and a LiteLLM hub under
$AI_HUB_DIR. Binds LiteLLM to the Tailscale IPv4 only (never 0.0.0.0).

Options:
  --dry-run       Plan only; no package installs, no durable writes
  --lockdown      Apply UFW deny-incoming + allow on tailscale0 (explicit opt-in)
  --with-webui    Also start optional Open WebUI (--profile webui)
  --help          Show this help

Safer than curl|bash:
  curl -fsSL $AI_HUB_REPO_RAW/install.sh -o install.sh
  less install.sh
  sudo env TS_AUTHKEY=... OPENROUTER_API_KEY=... bash install.sh

License / ToS: read the README before you spend a dollar (LiteLLM MIT outside
enterprise/, OpenRouter no-resale, Docker, Tailscale Personal).
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (sudo). Or pass --dry-run to preview."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --lockdown) LOCKDOWN=1; shift ;;
      --with-webui) WITH_WEBUI=1; shift ;;
      --skip-webui) WITH_WEBUI=0; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

detect_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "No /etc/os-release — this installer targets Ubuntu 22.04/24.04."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) log "Detected Ubuntu ${VERSION_ID}" ;;
    ubuntu:*)
      warn "Ubuntu ${VERSION_ID} is untested; continuing (22.04/24.04 recommended)."
      ;;
    *)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Non-Ubuntu host (${ID:-unknown}); dry-run continues."
      else
        die "Unsupported OS (${ID:-unknown} ${VERSION_ID:-}). Use Ubuntu 22.04 or 24.04."
      fi
      ;;
  esac
}

rand_hex() {
  local n="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$n"
    return 0
  fi
  # Fallback without openssl/xxd (busy containers)
  local hex="" byte
  while [[ ${#hex} -lt $((n * 2)) ]]; do
    byte="$(od -An -N1 -tx1 /dev/urandom 2>/dev/null | tr -d " \n")"
    hex+="${byte}"
  done
  printf "%s\n" "${hex:0:$((n * 2))}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine + Compose already present — skipping install."
    docker --version || true
    docker compose version || true
    return 0
  fi
  log "Installing Docker Engine + Compose plugin (official convenience script)."
  # Copy: https://docs.docker.com/engine/install/ubuntu/#install-using-the-convenience-script
  # and https://get.docker.com/
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] curl -fsSL https://get.docker.com | sh\n'
    printf '[dry-run] systemctl enable --now docker\n'
    return 0
  fi
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  systemctl enable --now docker
  docker --version
  docker compose version
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale binary present — skipping package install."
  else
    log "Installing Tailscale (official install script)."
    # Copy: https://tailscale.com/download/linux
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] curl -fsSL https://tailscale.com/install.sh | sh\n'
    else
      curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh
      sh /tmp/tailscale-install.sh
      rm -f /tmp/tailscale-install.sh
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] would run: tailscale up --authkey=<TS_AUTHKEY> --hostname=%s --ssh\n' "$AI_HUB_HOSTNAME"
    return 0
  fi

  if tailscale status >/dev/null 2>&1; then
    log "Tailscale already up — leaving existing session."
    return 0
  fi

  local key="${TS_AUTHKEY:-}"
  if [[ -z "$key" ]]; then
    if [[ -t 0 ]]; then
      printf 'Enter Tailscale auth key (TS_AUTHKEY), empty to abort: '
      # hidden-ish: still visible on some terminals; prefer env for automation
      read -r key
    fi
  fi
  [[ -n "$key" ]] || die "TS_AUTHKEY is required (export it or enter when prompted). No default."

  # Do not echo the key
  tailscale up --authkey="$key" --hostname="$AI_HUB_HOSTNAME" --ssh
  log "Tailscale up requested for hostname=${AI_HUB_HOSTNAME}"
}

detect_tailscale_ip() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Placeholder teaching string only — not a real address
    HUB_BIND_IP="${HUB_BIND_IP:-<YOUR_TAILSCALE_IP>}"
    log "Dry-run bind IP placeholder: $HUB_BIND_IP"
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1; then
    die "tailscale not found after install."
  fi
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -n "$ip" ]] || die "Could not read Tailscale IPv4 (tailscale ip -4). Is the node online?"
  # Refuse obvious public bind mistakes
  if [[ "$ip" == "0.0.0.0" ]]; then
    die "Refusing to bind to 0.0.0.0"
  fi
  HUB_BIND_IP="$ip"
  log "Will bind LiteLLM to Tailscale IPv4 (value kept out of this log; see $AI_HUB_DIR/.env)."
}

fetch_stack_files() {
  log "Preparing $AI_HUB_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] mkdir -p %s\n' "$AI_HUB_DIR"
    printf '[dry-run] install docker-compose.yml + litellm_config.yaml\n'
    return 0
  fi
  mkdir -p "$AI_HUB_DIR"

  local compose_src config_src
  if [[ -n "$AI_HUB_LOCAL_DIR" ]]; then
    compose_src="$AI_HUB_LOCAL_DIR/docker-compose.yml"
    config_src="$AI_HUB_LOCAL_DIR/litellm_config.example.yaml"
    [[ -f "$compose_src" ]] || die "Missing $compose_src"
    [[ -f "$config_src" ]] || die "Missing $config_src"
    cp "$compose_src" "$AI_HUB_DIR/docker-compose.yml"
    cp "$config_src" "$AI_HUB_DIR/litellm_config.yaml"
  else
    curl -fsSL "$AI_HUB_REPO_RAW/docker-compose.yml" -o "$AI_HUB_DIR/docker-compose.yml"
    curl -fsSL "$AI_HUB_REPO_RAW/litellm_config.example.yaml" -o "$AI_HUB_DIR/litellm_config.yaml"
  fi
  # Also keep the example name for humans who diff against the guide
  if [[ ! -f "$AI_HUB_DIR/litellm_config.example.yaml" ]]; then
    cp "$AI_HUB_DIR/litellm_config.yaml" "$AI_HUB_DIR/litellm_config.example.yaml"
  fi
}

write_env_file() {
  local env_path="$AI_HUB_DIR/.env"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] would write %s mode 600 (generate secrets; never echo values)\n' "$env_path"
    return 0
  fi

  if [[ -f "$env_path" ]]; then
    log "Existing $env_path found — preserving secrets (idempotent)."
    # Refresh HUB_BIND_IP if Tailscale IP changed
    if grep -q '^HUB_BIND_IP=' "$env_path"; then
      # rewrite only HUB_BIND_IP line
      local tmp
      tmp="$(mktemp)"
      # shellcheck disable=SC2016
      awk -v ip="$HUB_BIND_IP" '
        BEGIN{done=0}
        /^HUB_BIND_IP=/ {print "HUB_BIND_IP=" ip; done=1; next}
        {print}
        END{if(!done) print "HUB_BIND_IP=" ip}
      ' "$env_path" >"$tmp"
      cat "$tmp" >"$env_path"
      rm -f "$tmp"
      chmod 600 "$env_path"
    fi
    return 0
  fi

  local or_key="${OPENROUTER_API_KEY:-}"
  if [[ -z "$or_key" ]]; then
    if [[ -t 0 ]]; then
      printf 'Enter OpenRouter API key (input hidden): '
      # shellcheck disable=SC2162
      read -s or_key
      printf '\n'
    fi
  fi
  [[ -n "$or_key" ]] || die "OPENROUTER_API_KEY is required (export it or enter when prompted)."

  local litellm_key salt_key pg_pass webui_secret
  litellm_key="$(rand_hex 32)"
  salt_key="$(rand_hex 32)"
  pg_pass="$(rand_hex 24)"
  webui_secret="$(rand_hex 32)"

  umask 077
  cat >"$env_path" <<EOF
# Generated by install.sh — mode 600. Never commit.
HUB_BIND_IP=${HUB_BIND_IP}
POSTGRES_PASSWORD=${pg_pass}
LITELLM_MASTER_KEY=${litellm_key}
LITELLM_SALT_KEY=${salt_key}
OPENROUTER_API_KEY=${or_key}
WEBUI_SECRET_KEY=${webui_secret}
EOF
  chmod 600 "$env_path"
  log "Wrote secrets to $env_path (mode 600). Values are not printed."
}

print_firewall_advice() {
  cat <<EOF

--- Firewall lockdown advice ---
Cloud firewall: after Tailscale SSH works, empty inbound rules.
On-box UFW (manual, or re-run with --lockdown):

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0 to any
  ufw allow OpenSSH   # keep until Tailscale SSH is proven, then you may remove
  ufw --force enable
  ufw status verbose

Prove the lock:
  From OFF your tailnet: curl to public :4000 must FAIL
  From ON your tailnet:  curl http://<YOUR_TAILSCALE_IP>:4000/health/liveliness → 200
-------------------------------
EOF
}

apply_lockdown() {
  if [[ "$LOCKDOWN" -ne 1 ]]; then
    log "Skipping UFW apply (pass --lockdown to opt in)."
    print_firewall_advice
    return 0
  fi
  log "Applying UFW lockdown (--lockdown)."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] ufw default deny incoming\n'
    printf '[dry-run] ufw default allow outgoing\n'
    printf '[dry-run] ufw allow in on tailscale0 to any\n'
    printf '[dry-run] ufw allow OpenSSH\n'
    printf '[dry-run] ufw --force enable\n'
    return 0
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not installed; printing advice only."
    print_firewall_advice
    return 0
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0 to any || true
  ufw allow OpenSSH || true
  ufw --force enable
  ufw status verbose || true
}

compose_up() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] cd %s && docker compose up -d\n' "$AI_HUB_DIR"
    if [[ "$WITH_WEBUI" -eq 1 ]]; then
      printf '[dry-run] docker compose --profile webui up -d\n'
    fi
    return 0
  fi
  cd "$AI_HUB_DIR"
  # Export for compose variable substitution
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  if [[ "$WITH_WEBUI" -eq 1 ]]; then
    docker compose --profile webui up -d
  else
    docker compose up -d
  fi
  docker compose ps
}

wait_healthy() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] wait for LiteLLM health on Tailscale bind\n'
    return 0
  fi
  local url="http://${HUB_BIND_IP}:4000/health/liveliness"
  local _i
  log "Waiting for health at Tailscale-bound :4000 ..."
  for _i in $(seq 1 "$AI_HUB_HEALTH_RETRIES"); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      log "Health endpoint responded."
      return 0
    fi
    sleep 2
  done
  warn "Health wait timed out — see: docker compose -f $AI_HUB_DIR/docker-compose.yml logs litellm --tail 100"
  return 1
}

run_tests() {
  local health_ok=0
  local chat_ok=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] health check → would print PASS/FAIL\n'
    printf '[dry-run] tiny completion → would print PASS/FAIL\n'
    log "DRY-RUN complete. No packages installed; no secrets written."
    return 0
  fi

  local url="http://${HUB_BIND_IP}:4000/health/liveliness"
  if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
    health_ok=1
    printf 'HEALTH: PASS\n'
  else
    printf 'HEALTH: FAIL\n'
  fi

  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  . "$AI_HUB_DIR/.env"
  set +a

  local resp
  if resp="$(curl -fsS --max-time 60 "http://${HUB_BIND_IP}:4000/v1/chat/completions" \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"model":"bulk-small","messages":[{"role":"user","content":"Reply OK in three words."}]}' 2>/dev/null)"; then
    if printf '%s' "$resp" | grep -qi 'choices\|content\|OK\|ok'; then
      chat_ok=1
      printf 'TEST_COMPLETION: PASS\n'
    else
      printf 'TEST_COMPLETION: FAIL (unexpected body)\n'
    fi
  else
    printf 'TEST_COMPLETION: FAIL (request error — check OpenRouter credit / key)\n'
  fi

  if [[ "$health_ok" -eq 1 && "$chat_ok" -eq 1 ]]; then
    printf '\nOVERALL: PASS\n'
  else
    printf '\nOVERALL: FAIL\n'
    return 1
  fi
}

print_next_steps() {
  cat <<EOF

Install finished (or dry-run planned).

App dir:     $AI_HUB_DIR
Secrets:     $AI_HUB_DIR/.env  (mode 600 — values never echoed here)
Compose:     $AI_HUB_DIR/docker-compose.yml
Config:      $AI_HUB_DIR/litellm_config.yaml

Useful:
  cd $AI_HUB_DIR && docker compose ps
  cd $AI_HUB_DIR && docker compose logs litellm --tail 100
  # Optional UI:
  cd $AI_HUB_DIR && docker compose --profile webui up -d

Uninstall:
  sudo bash uninstall.sh
  # or: curl -fsSL $AI_HUB_REPO_RAW/uninstall.sh -o uninstall.sh && sudo bash uninstall.sh

Read the README privacy gate: non-private bulk work only.
Never turn on OpenRouter Auto Recharge from a script.
EOF
}

main() {
  parse_args "$@"
  need_root
  detect_ubuntu
  install_docker
  install_tailscale
  detect_tailscale_ip
  fetch_stack_files
  write_env_file
  apply_lockdown
  compose_up
  wait_healthy || true
  local test_rc=0
  run_tests || test_rc=$?
  print_next_steps
  return "$test_rc"
}

main "$@"
exit $?
