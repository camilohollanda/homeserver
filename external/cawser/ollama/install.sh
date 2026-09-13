#!/usr/bin/env bash
# Native Ollama on an existing Debian/Ubuntu x86_64 NVIDIA host.
# Local: sudo bash install.sh
# Remote: REMOTE_HOST=camilo@192.168.0.107 bash install.sh
# Preview (no SSH, downloads or writes): bash install.sh --dry-run
set -euo pipefail

fail() { echo "Error: $*" >&2; exit 1; }

MARKER='# Managed by external/cawser/ollama/install.sh'

configure() {
  MODE="${1:-install}"
  [[ $# -le 1 ]] || fail "expected at most one argument"
  case "$MODE" in
    install|--dry-run) ;;
    --help|-h) echo "Usage: $0 [--dry-run] (configuration: see README.md)"; exit 0 ;;
    *) fail "unknown argument: $MODE" ;;
  esac

  OLLAMA_VERSION="${OLLAMA_VERSION:-0.34.0}"
  if [[ -z "${OLLAMA_ARCHIVE_SHA256:-}" && "$OLLAMA_VERSION" == 0.34.0 ]]; then
    OLLAMA_ARCHIVE_SHA256=cf95886728959aa09910bb34de5cca1cc5a8f68003b5597197d3f2c2d57c0804
  fi
  OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder:30b}"
  if [[ -z "${OLLAMA_MODEL_SHA256:-}" && "$OLLAMA_MODEL" == qwen3-coder:30b ]]; then
    OLLAMA_MODEL_SHA256=06c1097efce0431c2045fe7b2e5108366e43bee1b4603a7aded8f21689e90bca
  fi
  OLLAMA_DATA_MOUNT="${OLLAMA_DATA_MOUNT:-/dados}"
  OLLAMA_MODELS="${OLLAMA_MODELS:-${OLLAMA_DATA_MOUNT}/ollama/models}"
  OLLAMA_PORT="${OLLAMA_PORT:-11434}"
  OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-16384}"
  OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
  OLLAMA_VERIFY_GPU="${OLLAMA_VERIFY_GPU:-1}"

  [[ "$OLLAMA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "OLLAMA_VERSION must be an explicit stable version"
  [[ "${OLLAMA_ARCHIVE_SHA256:-}" =~ ^[a-f0-9]{64}$ ]] || fail "OLLAMA_ARCHIVE_SHA256 is required for this version"
  [[ "$OLLAMA_MODEL" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]] || fail "OLLAMA_MODEL must include an explicit tag"
  [[ "$OLLAMA_MODEL" != *cloud* ]] || fail "cloud models are not supported by this local installer"
  [[ "${OLLAMA_MODEL_SHA256:-}" =~ ^[a-f0-9]{64}$ ]] || fail "OLLAMA_MODEL_SHA256 is required for this model"
  if [[ ! "$OLLAMA_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( OLLAMA_PORT > 65535 )); then
    fail "invalid OLLAMA_PORT"
  fi
  [[ "$OLLAMA_CONTEXT_LENGTH" =~ ^[1-9][0-9]{0,6}$ ]] || fail "invalid OLLAMA_CONTEXT_LENGTH"
  [[ "$OLLAMA_NUM_PARALLEL" == 1 ]] || fail "OLLAMA_NUM_PARALLEL must remain 1 on this shared GPU"
  [[ "$OLLAMA_VERIFY_GPU" == 0 || "$OLLAMA_VERIFY_GPU" == 1 ]] || fail "OLLAMA_VERIFY_GPU must be 0 or 1"
  for value in "$OLLAMA_DATA_MOUNT" "$OLLAMA_MODELS"; do
    [[ "$value" =~ ^/[a-zA-Z0-9_/-]+$ && "$value" != / && "$value" != */ && "$value" != *//* ]] \
      || fail "use an absolute data path without whitespace, dots or a trailing slash"
  done
  [[ "$OLLAMA_MODELS" == "$OLLAMA_DATA_MOUNT/"* ]] || fail "OLLAMA_MODELS must be below OLLAMA_DATA_MOUNT"

  BASE=/opt/ollama-native
  API="http://127.0.0.1:${OLLAMA_PORT}"
  ARCHIVE_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst"
}

render_environment() {
  cat <<EOF
$MARKER
OLLAMA_HOST=127.0.0.1:${OLLAMA_PORT}
OLLAMA_MODELS=${OLLAMA_MODELS}
OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}
OLLAMA_NUM_PARALLEL=1
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_MAX_QUEUE=16
OLLAMA_KEEP_ALIVE=5m
OLLAMA_FLASH_ATTENTION=1
OLLAMA_KV_CACHE_TYPE=q8_0
OLLAMA_NO_CLOUD=1
EOF
}

render_service() {
  cat <<EOF
$MARKER
[Unit]
Description=Native Ollama inference server
Wants=network-online.target
After=network-online.target
RequiresMountsFor=${OLLAMA_DATA_MOUNT}
ConditionPathIsMountPoint=${OLLAMA_DATA_MOUNT}

[Service]
Type=simple
User=ollama
Group=ollama
StateDirectory=ollama
Environment=HOME=/var/lib/ollama
EnvironmentFile=/etc/ollama-native.env
ExecStart=${BASE}/current/bin/ollama serve
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${OLLAMA_MODELS}

[Install]
WantedBy=multi-user.target
EOF
}

# These read-only checks are also used immediately before their mutations.
check_model_storage() {
  local contents model_marker="$OLLAMA_MODELS/.ollama-native-managed"
  mountpoint -q "$OLLAMA_DATA_MOUNT" \
    || fail "${OLLAMA_DATA_MOUNT} is not mounted; refusing to use the root disk"
  [[ "$(realpath -e "$OLLAMA_DATA_MOUNT")" == "$OLLAMA_DATA_MOUNT" \
     && "$(realpath -m "$OLLAMA_MODELS")" == "$OLLAMA_MODELS" ]] \
    || fail "data paths must not contain symlinks; refusing to write outside the mounted storage"
  if [[ -e "$OLLAMA_MODELS" ]]; then
    [[ -d "$OLLAMA_MODELS" ]] || fail "${OLLAMA_MODELS} is not a directory"
    contents="$(find "$OLLAMA_MODELS" -mindepth 1 -maxdepth 1 -print -quit)"
    if [[ -n "$contents" ]]; then
      if [[ -L "$model_marker" || ! -f "$model_marker" ]] || ! grep -Fxq "$MARKER" "$model_marker"; then
        fail "unmanaged nonempty model directory at ${OLLAMA_MODELS}; migrate it explicitly first"
      fi
    fi
  fi
}

check_port_ownership() {
  local required="${1:-0}" listeners existing_unit main_pid listener address process
  listeners="$(ss -H -lntp "sport = :${OLLAMA_PORT}")"
  if [[ -z "$listeners" ]]; then
    [[ "$required" == 0 ]] || fail "the managed Ollama service has no listener on port ${OLLAMA_PORT}"
    return 0
  fi
  existing_unit="$(systemctl show ollama.service -p FragmentPath --value)"
  main_pid="$(systemctl show ollama.service -p MainPID --value)"
  if [[ "$existing_unit" != "$SERVICE" || ! "$main_pid" =~ ^[1-9][0-9]*$ ]] \
     || ! grep -Fxq "$MARKER" "$SERVICE"; then
    fail "port ${OLLAMA_PORT} is already in use by another server"
  fi
  systemctl is-active --quiet ollama.service || fail "the managed Ollama service is not active"
  while IFS= read -r listener; do
    read -r _ _ _ address _ process <<< "$listener"
    [[ "$process" == *"pid=${main_pid},"* ]] \
      || fail "port ${OLLAMA_PORT} has a listener outside the managed Ollama service"
    [[ "$address" == "127.0.0.1:${OLLAMA_PORT}" ]] \
      || fail "the managed Ollama listener must bind only to 127.0.0.1:${OLLAMA_PORT}"
  done <<< "$listeners"
}

model_digest() {
  curl -fsS --max-time 10 "$API/api/tags" \
    | jq -r --arg model "$OLLAMA_MODEL" '.models[] | select(.name == $model or .model == $model) | .digest'
}

ensure_model() {
  local digest
  digest="$(model_digest)"
  if [[ -z "$digest" ]]; then
    echo "==> Downloading ${OLLAMA_MODEL}..."
    check_port_ownership 1
    OLLAMA_HOST="$API" "$BASE/current/bin/ollama" pull "$OLLAMA_MODEL"
    digest="$(model_digest)"
  fi
  [[ "${digest#sha256:}" == "$OLLAMA_MODEL_SHA256" ]] \
    || fail "model SHA256 differs from the pinned manifest; review the tag change instead of silently accepting it"
}

verify_gpu() {
  echo "==> One-token GPU smoke check (loads the model)..."
  jq -n --arg model "$OLLAMA_MODEL" --argjson ctx "$OLLAMA_CONTEXT_LENGTH" \
    '{model:$model,prompt:"Reply OK.",stream:false,options:{num_predict:1,num_ctx:$ctx}}' > "$WORK/request.json"
  check_port_ownership 1
  curl -fsS --max-time 600 -H 'Content-Type: application/json' \
    --data-binary @"$WORK/request.json" "$API/api/generate" > "$WORK/generation.json"
  jq -e '.done == true and .error == null' "$WORK/generation.json" >/dev/null \
    || fail "generation failed; inspect journalctl -u ollama"
  curl -fsS --max-time 10 "$API/api/ps" > "$WORK/ps.json"
  jq -e --arg model "$OLLAMA_MODEL" \
    '.models[] | select(.name == $model or .model == $model) | .size > 0 and .size_vram >= .size' \
    "$WORK/ps.json" >/dev/null \
    || fail "model is not fully on GPU; inspect ollama /api/ps and reduce context or choose a smaller model"
}

main() {
  configure "$@"
  if [[ "$MODE" == --dry-run ]]; then
    echo "Native Ollama ${OLLAMA_VERSION}; Linux amd64; NVIDIA driver required"
    echo "Archive: ${ARCHIVE_URL}"
    echo "Archive SHA256: ${OLLAMA_ARCHIVE_SHA256}"
    echo "Model: ${OLLAMA_MODEL}; SHA256: ${OLLAMA_MODEL_SHA256}"
    echo "Required mount: ${OLLAMA_DATA_MOUNT}; GPU smoke check: ${OLLAMA_VERIFY_GPU}"
    render_environment
    render_service
    exit 0
  fi

  # Forward only this installer's settings, using Bash quoting rather than
  # interpolating configuration into the remote shell command.
  if [[ -n "${REMOTE_HOST:-}" ]]; then
    {
      for key in OLLAMA_VERSION OLLAMA_ARCHIVE_SHA256 OLLAMA_MODEL OLLAMA_MODEL_SHA256 \
        OLLAMA_DATA_MOUNT OLLAMA_MODELS OLLAMA_PORT OLLAMA_CONTEXT_LENGTH \
        OLLAMA_NUM_PARALLEL OLLAMA_VERIFY_GPU; do
        printf 'export %s=%q\n' "$key" "${!key}"
      done
      cat "$0"
    } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" sudo -n bash -s
    exit $?
  fi

  [[ "$EUID" -eq 0 ]] || fail "run as root, or use setup.sh / REMOTE_HOST"
  # Release directories must remain traversable by the unprivileged service.
  umask 022
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail "requires Linux x86_64"
  command -v apt-get >/dev/null || fail "requires a Debian/Ubuntu host"
  command -v systemctl >/dev/null || fail "requires systemd"
  check_model_storage
  if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L; then
    fail "NVIDIA driver is unavailable; drivers are never installed by this script"
  fi

  exec 9>/run/lock/ollama-native-install.lock
  flock -n 9 || fail "another Ollama installation is in progress"
  SERVICE=/etc/systemd/system/ollama.service
  EXISTING_UNIT="$(systemctl show ollama.service -p FragmentPath --value)"
  if [[ -n "$EXISTING_UNIT" ]]; then
    if [[ "$EXISTING_UNIT" != "$SERVICE" ]] || ! grep -Fxq "$MARKER" "$SERVICE"; then
      fail "an unmanaged ollama.service exists; migrate it explicitly first"
    fi
  fi
  check_port_ownership
  [[ ! -e /etc/ollama-native.env ]] || grep -Fxq "$MARKER" /etc/ollama-native.env \
    || fail "/etc/ollama-native.env is not managed by this installer"
  if [[ -d "$BASE" ]]; then
    [[ -f "$BASE/.managed" ]] || fail "${BASE} already exists without this installer's marker"
  fi

  echo "==> Installing download tools (no Docker or driver changes)..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates zstd jq
  install -d -m 0755 "$BASE/releases"
  touch "$BASE/.managed"
  WORK="$(mktemp -d "$BASE/.install.XXXXXX")"
  trap 'rm -rf -- "$WORK"' EXIT
  RELEASE="$BASE/releases/$OLLAMA_VERSION"
  CHANGED=0

  if [[ -e "$RELEASE" ]]; then
    [[ -x "$RELEASE/bin/ollama" && -f "$RELEASE/.archive-sha256" ]] \
      || fail "incomplete release at ${RELEASE}; inspect it before retrying"
    [[ "$(cat "$RELEASE/.archive-sha256")" == "$OLLAMA_ARCHIVE_SHA256" ]] \
      || fail "installed release checksum does not match the requested version"
  else
    echo "==> Downloading Ollama ${OLLAMA_VERSION}..."
    curl -fL --retry 3 --connect-timeout 15 --max-time 3600 "$ARCHIVE_URL" -o "$WORK/ollama.tar.zst"
    printf '%s  %s\n' "$OLLAMA_ARCHIVE_SHA256" "$WORK/ollama.tar.zst" | sha256sum -c -
    mkdir "$WORK/release"
    tar --zstd -xf "$WORK/ollama.tar.zst" -C "$WORK/release"
    [[ -x "$WORK/release/bin/ollama" ]] || fail "archive does not contain bin/ollama"
    printf '%s\n' "$OLLAMA_ARCHIVE_SHA256" > "$WORK/release/.archive-sha256"
    mv "$WORK/release" "$RELEASE"
  fi

  if ! id ollama >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/ollama --no-create-home --shell /usr/sbin/nologin ollama
  fi
  for group in video render; do
    if getent group "$group" >/dev/null; then usermod -aG "$group" ollama; fi
  done
  # Recheck after downloading, before changing any model-directory ownership.
  check_model_storage
  # Only own the model directory itself; never recursively chown /dados.
  install -d -m 0700 -o ollama -g ollama "$OLLAMA_MODELS"
  printf '%s\n' "$MARKER" > "$WORK/model-owner"
  install -m 0644 "$WORK/model-owner" "$OLLAMA_MODELS/.ollama-native-managed"
  render_environment > "$WORK/ollama.env"
  render_service > "$WORK/ollama.service"
  if ! cmp -s "$WORK/ollama.env" /etc/ollama-native.env; then
    install -m 0644 "$WORK/ollama.env" /etc/ollama-native.env
    CHANGED=1
  fi
  if ! cmp -s "$WORK/ollama.service" "$SERVICE"; then
    install -m 0644 "$WORK/ollama.service" "$SERVICE"
    CHANGED=1
  fi
  if [[ "$(readlink "$BASE/current" || true)" != "$RELEASE" ]]; then
    [[ ! -e "$BASE/current" || -L "$BASE/current" ]] || fail "${BASE}/current must be a symlink"
    ln -s "$RELEASE" "$WORK/current"
    mv -Tf "$WORK/current" "$BASE/current"
    CHANGED=1
  fi
  systemctl daemon-reload
  systemctl enable --quiet ollama.service
  if (( CHANGED )); then systemctl restart ollama.service; else systemctl start ollama.service; fi

  echo "==> Waiting for ${API}..."
  READY=0
  for ((attempt=0; attempt<30; attempt++)); do
    if systemctl is-active --quiet ollama.service \
       && curl -fsS --max-time 2 "$API/api/version" > "$WORK/version.json" \
       && jq -e --arg version "$OLLAMA_VERSION" '.version == $version' "$WORK/version.json" >/dev/null; then
      READY=1
      break
    fi
    sleep 2
  done
  (( READY )) || fail "Ollama did not become ready; inspect journalctl -u ollama"

  check_port_ownership 1
  ensure_model
  if [[ "$OLLAMA_VERIFY_GPU" == 1 ]]; then verify_gpu; fi
  echo "==> Ollama ${OLLAMA_VERSION} ready at ${API}; model ${OLLAMA_MODEL} matches its pinned digest."
}

# BASH_SOURCE is unset for the SSH stdin form: sudo bash -s.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
