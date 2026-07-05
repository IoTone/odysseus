#!/usr/bin/env bash
# apple-container-stack.sh — Run the Odysseus product tier under Apple `container`
# instead of Docker Compose, on macOS 26+ (Apple Silicon).
#
# WHY THIS EXISTS
#   docker-compose.yml runs a 4-service stack (odysseus app + chromadb + searxng
#   + ntfy). None of them need the GPU — the accelerated model (ollama) already
#   runs NATIVELY on the host and is reached over HTTP. That's the exact topology
#   documented in apple-ml-containers.md, and it's what makes Apple `container`
#   (which has NO GPU passthrough) a viable drop-in for this tier.
#
#   Apple `container` has no `compose`, so this script hand-rolls what compose
#   gave us for free. It also translates the compose-isms that don't exist under
#   Apple `container` (see "TRANSLATION NOTES" below).
#
# USAGE
#   scripts/apple-container-stack.sh up          # build image + start all 4 services
#   scripts/apple-container-stack.sh down        # stop + remove all 4 services
#   scripts/apple-container-stack.sh ps          # list stack containers
#   scripts/apple-container-stack.sh logs [svc]  # tail logs (default: odysseus)
#   scripts/apple-container-stack.sh password    # print the first admin password
#   scripts/apple-container-stack.sh help
#
# PREREQUISITES
#   - macOS 26+ with Apple's `container` CLI installed (`brew install container`)
#   - One-time host setup (both verified necessary on a clean box):
#       container system start                      # installs a Linux kernel on first run
#       container system kernel set --recommended   # if the kernel step was skipped
#       softwareupdate --install-rosetta --agree-to-license   # buildkit needs Rosetta to build the image
#   - ollama running on the host AND bound so the container VM can reach it:
#       OLLAMA_HOST=0.0.0.0 ollama serve     # NOT the default 127.0.0.1-only bind
#     (Unlike Docker Desktop there is no `host.docker.internal`; the app reaches
#      ollama at the network gateway IP, and a loopback-only ollama is unreachable
#      from the container VM. Verified against container 1.0.0.)
#
# TRANSLATION NOTES (compose -> Apple `container`)  [verified against container 1.0.0]
#   host.docker.internal  -> the network GATEWAY IP (e.g. 192.168.65.1). Verified:
#                            a container reaches a host process via the gateway,
#                            but ONLY if that process binds 0.0.0.0 (loopback-only
#                            binds are unreachable). Hence the ollama caveat below.
#   service-name DNS      -> Apple `container` 1.0.0 does NOT resolve peer
#                            containers by `--name` on a user network (verified:
#                            "Name or service not known"). Name DNS needs a
#                            sudo-created `container system dns` domain. To stay
#                            sudo-free, this script resolves each peer's per-network
#                            IP via `container inspect` and injects it into the app.
#   named volumes         -> host bind dirs under ./data (searxng/, chromadb/, ntfy/)
#   depends_on: healthy   -> explicit HTTP poll loop before starting the app
#   cap_drop / cap_add    -> dropped; each container is its own hardware-isolated
#                            VM, so the searxng privilege tuning is unnecessary
#   :z (SELinux relabel)  -> dropped; a Docker/Podman-on-Linux concept, no-op here
#
# KNOWN QUIRK (container 1.0.0): a freshly-attached container occasionally comes
#   up with no working in-network route (peers get "no route to host") even
#   though it is "running" and listening. `up` detects this for chromadb and
#   restarts it once, which re-attaches cleanly. IPs are re-resolved after any
#   restart, so the app always receives a reachable address.
#
# LIMITATION: because container 1.0.0 has no name DNS without a sudo-created
#   `container system dns` domain, the app gets peer IPs baked in at start. If you
#   later restart chromadb/searxng on their own, their IP changes and the app's
#   env goes stale — re-run `up` (or set up a DNS domain) after such a restart.
set -euo pipefail

# ─── config ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${IMAGE:-odysseus:local}"
NET="${NET:-odysseus}"

APP_BIND="${APP_BIND:-127.0.0.1}"
APP_PORT="${APP_PORT:-7000}"
CHROMADB_BIND="${CHROMADB_BIND:-127.0.0.1}"
NTFY_BIND="${NTFY_BIND:-127.0.0.1}"

DATA_DIR="${APP_DATA_DIR:-$REPO_ROOT/data}"
LOGS_DIR="${APP_LOGS_DIR:-$REPO_ROOT/logs}"

# Pinned to match docker-compose.yml — searxng :latest can ship a boot-breaking
# tag (see the comment on the searxng service in docker-compose.yml).
SEARXNG_IMAGE="docker.io/searxng/searxng:2026.5.31-7159b8aed"
CHROMADB_IMAGE="docker.io/chromadb/chroma:latest"
NTFY_IMAGE="docker.io/binwiederhier/ntfy"
PROBE_IMAGE="docker.io/library/python:3.14-slim"  # tiny helper for in-network reachability checks

# ─── output helpers (mirrors scripts/check-docker-gpu.sh) ────────────────────
_info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
_step() { printf '\033[36m[STEP]\033[0m %s\n' "$*"; }
_die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ─── preflight ───────────────────────────────────────────────────────────────
require_container() {
  command -v container >/dev/null 2>&1 \
    || _die "Apple 'container' CLI not found. Install from https://github.com/apple/container (needs macOS 26+)."
}

# A container's per-network IPv4 (no `/mask`). Empty if not running yet.
container_ip() {
  container inspect "$1" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)[0]['status']['networks'][0]
    print(d['ipv4Address'].split('/')[0])
except Exception:
    pass
" 2>/dev/null
}

# The network gateway == the host, as seen from inside the VM. This is how the
# app reaches host-native ollama (there is no host.docker.internal). Read it off
# any running container on our network; override with HOST_IP= if needed.
gateway_ip() {
  if [ -n "${HOST_IP:-}" ]; then printf '%s' "$HOST_IP"; return; fi
  container inspect "$1" 2>/dev/null | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)[0]['status']['networks'][0]['ipv4Gateway'])
except Exception:
    pass
" 2>/dev/null
}

# ─── lifecycle ───────────────────────────────────────────────────────────────
ensure_system() {
  require_container
  # `container system start` is idempotent; brings up the helper VM/daemon.
  container system start >/dev/null 2>&1 || true
  container network create "$NET" >/dev/null 2>&1 || true  # idempotent
}

ensure_dirs() {
  # Named-volume replacements (compose used searxng-data/chromadb-data/ntfy-cache)
  # plus the app's bind mounts. Kept under ./data so `down` never touches them.
  mkdir -p \
    "$DATA_DIR" "$LOGS_DIR" \
    "$DATA_DIR/ssh" "$DATA_DIR/huggingface" "$DATA_DIR/local" \
    "$DATA_DIR/searxng" "$DATA_DIR/chromadb" "$DATA_DIR/ntfy"
}

stop_one() {
  container stop "$1" >/dev/null 2>&1 || true
  container rm "$1"   >/dev/null 2>&1 || true
}

# Poll a host-published endpoint until it answers, reproducing compose's
# `depends_on: condition: service_healthy` ordering. Polled from the host (not
# `container exec`) against the published port, so it needs nothing in the image.
wait_http() {
  local name="$1" url="$2" tries="${3:-40}"
  _step "waiting for $name ($url) ..."
  for _ in $(seq "$tries"); do
    if python3 -c "import urllib.request; urllib.request.urlopen('$url',timeout=3).read(1)" >/dev/null 2>&1; then
      _info "$name is up"; return 0
    fi
    sleep 2
  done
  _die "$name did not become healthy in time (check: $0 logs $name)"
}

# True if ip:port accepts a TCP connection from *inside* the network. Spawns a
# throwaway container because the transient no-route only shows container-to-
# container, not always on the host-published port.
peer_reachable() {
  local ip="$1" port="$2"
  container run --rm --network "$NET" "$PROBE_IMAGE" \
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(6);
sys.exit(0 if s.connect_ex(('$ip',$port))==0 else 1)" >/dev/null 2>&1
}

# Service starts, factored out so they can be re-run on a restart.
run_chromadb() {
  _step "starting chromadb"
  container run -d --name chromadb --network "$NET" \
    -p "${CHROMADB_BIND}:8100:8000" \
    -v "$DATA_DIR/chromadb:/chroma/chroma" \
    -e ANONYMIZED_TELEMETRY=FALSE \
    "$CHROMADB_IMAGE" >/dev/null
}

run_searxng() {
  # Same first-boot wrapper as docker-compose.yml: seed a secret into
  # settings.yml from the mounted template on first run. cap_drop/cap_add from
  # compose is intentionally omitted — the VM boundary already isolates it.
  _step "starting searxng"
  container run -d --name searxng --network "$NET" \
    -p "127.0.0.1:8080:8080" \
    -v "$DATA_DIR/searxng:/etc/searxng" \
    -v "$REPO_ROOT/config/searxng/settings.yml:/tmp/searxng-settings.yml.template:ro" \
    -e "SEARXNG_BASE_URL=http://localhost:8080/" \
    -e "SEARXNG_SECRET=${SEARXNG_SECRET:-}" \
    --entrypoint /bin/sh \
    "$SEARXNG_IMAGE" -c '
      set -eu
      if [ ! -s /etc/searxng/settings.yml ] || grep -q "odysseus-local-searxng-json-2026-05-30\|__SEARXNG_SECRET__" /etc/searxng/settings.yml; then
        secret="${SEARXNG_SECRET:-}"
        [ -z "$secret" ] && secret="$(python -c "import secrets; print(secrets.token_urlsafe(48))")"
        sed "s|__SEARXNG_SECRET__|$secret|g" /tmp/searxng-settings.yml.template > /etc/searxng/settings.yml
      fi
      exec /usr/local/searxng/entrypoint.sh' >/dev/null
}

# Resolve a peer container's per-network IP, retrying until the VM has an address.
resolve_ip() {
  local name="$1" ip
  for _ in $(seq 20); do
    ip="$(container_ip "$name")"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    sleep 1
  done
  _die "could not resolve an IP for $name (check: $0 logs $name)"
}

up() {
  ensure_system
  ensure_dirs

  _step "building app image ($IMAGE)"
  container build -t "$IMAGE" -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"

  # tear down any prior instances so names are free (idempotent `up`)
  stop_one odysseus; stop_one chromadb; stop_one searxng; stop_one ntfy

  # ── chromadb ──────────────────────────────────────────────────────────────
  # Gate on readiness via the host-published port, then re-check that the peer is
  # actually reachable *in-network* by IP — container 1.0.0 occasionally attaches
  # a fresh container with no working route (verified), which a plain "is it
  # running" check misses. One restart clears it and it re-attaches cleanly.
  run_chromadb
  wait_http chromadb "http://127.0.0.1:8100/api/v2/heartbeat"
  if ! peer_reachable "$(resolve_ip chromadb)" 8000; then
    _warn "chromadb came up with no in-network route; restarting once"
    stop_one chromadb; run_chromadb
    wait_http chromadb "http://127.0.0.1:8100/api/v2/heartbeat"
    peer_reachable "$(resolve_ip chromadb)" 8000 \
      || _die "chromadb still unreachable in-network after restart (check: $0 logs chromadb)"
  fi

  # ── ntfy ────────────────────────────────────────────────────────────────
  _step "starting ntfy"
  container run -d --name ntfy --network "$NET" \
    -p "${NTFY_BIND}:8091:80" \
    -v "$DATA_DIR/ntfy:/var/cache/ntfy" \
    -e "NTFY_BASE_URL=${NTFY_BASE_URL:-http://localhost:8091}" \
    "$NTFY_IMAGE" serve >/dev/null

  # ── searxng ─────────────────────────────────────────────────────────────
  run_searxng
  wait_http searxng "http://127.0.0.1:8080/"

  # Resolve peer IPs + host gateway. container 1.0.0 has no name-based DNS on a
  # user network, so the app gets searxng/chromadb by IP and ollama via the
  # gateway (== the host). See TRANSLATION NOTES at the top.
  local searxng_ip chromadb_ip host_ip
  searxng_ip="$(resolve_ip searxng)"
  chromadb_ip="$(resolve_ip chromadb)"
  host_ip="${HOST_IP:-$(gateway_ip searxng)}"
  [ -z "$host_ip" ] && _die "could not determine the network gateway; set HOST_IP=<gateway>."
  _info "searxng=$searxng_ip  chromadb=$chromadb_ip  host/ollama=$host_ip"
  _info "host ollama must bind 0.0.0.0 to be reachable: OLLAMA_HOST=0.0.0.0 ollama serve"

  # ── odysseus app ────────────────────────────────────────────────────────
  _step "starting odysseus app"
  container run -d --name odysseus --network "$NET" \
    -p "${APP_BIND}:${APP_PORT}:7000" \
    -v "$DATA_DIR:/app/data" \
    -v "$LOGS_DIR:/app/logs" \
    -v "$DATA_DIR/ssh:/app/.ssh" \
    -v "$DATA_DIR/huggingface:/app/.cache/huggingface" \
    -v "$DATA_DIR/local:/app/.local" \
    -e "LLM_HOST=${LLM_HOST:-$host_ip}" \
    -e "OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://$host_ip:11434/v1}" \
    -e "SEARXNG_INSTANCE=http://$searxng_ip:8080" \
    -e "CHROMADB_HOST=$chromadb_ip" \
    -e "CHROMADB_PORT=8000" \
    -e "DATABASE_URL=${DATABASE_URL:-sqlite:///./data/app.db}" \
    -e "AUTH_ENABLED=${AUTH_ENABLED:-true}" \
    -e "LOCALHOST_BYPASS=${LOCALHOST_BYPASS:-false}" \
    -e "ODYSSEUS_ADMIN_USER=${ODYSSEUS_ADMIN_USER:-admin}" \
    -e "ODYSSEUS_ADMIN_PASSWORD=${ODYSSEUS_ADMIN_PASSWORD:-}" \
    -e "ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-http://localhost,http://127.0.0.1}" \
    -e "SECURE_COOKIES=${SECURE_COOKIES:-false}" \
    -e "PUID=${PUID:-1000}" \
    -e "PGID=${PGID:-1000}" \
    "$IMAGE" >/dev/null

  _info "stack is up"
  # Use 127.0.0.1, not localhost: macOS AirPlay Receiver (ControlCenter) also
  # listens on *:7000 incl. IPv6 ::1, so `localhost:7000` (IPv6-first) can hit
  # AirPlay's 403 instead of the app. The container publishes on 127.0.0.1 only.
  # Fix permanently by disabling System Settings > General > AirDrop & Handoff >
  # AirPlay Receiver, or set APP_PORT= to a non-7000 port.
  _info "open http://127.0.0.1:${APP_PORT}  (first admin password: $0 password)"
}

down() {
  require_container
  _step "stopping stack"
  stop_one odysseus; stop_one chromadb; stop_one searxng; stop_one ntfy
  _info "stopped (data under $DATA_DIR is preserved)"
}

ps_() { require_container; container ls -a | grep -E 'odysseus|chromadb|searxng|ntfy|NAME' || true; }

logs_() { require_container; container logs -f "${1:-odysseus}"; }

password_() {
  require_container
  # Mirrors: docker compose logs odysseus | grep -i password
  container logs odysseus 2>&1 | grep -i password || \
    _warn "no password line yet — the app may still be starting ($0 logs)"
}

case "${1:-help}" in
  up)       up ;;
  down)     down ;;
  ps)       ps_ ;;
  logs)     shift || true; logs_ "${1:-odysseus}" ;;
  password) password_ ;;
  help|-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) _die "unknown command: $1 (try: $0 help)" ;;
esac
