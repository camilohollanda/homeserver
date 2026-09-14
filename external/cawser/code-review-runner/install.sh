#!/usr/bin/env bash
# A dedicated, persistent review runner; no Docker, sudo grants or CI toolchains.
# Run via setup.sh or as root on a Debian 13 x86_64 host with native Ollama.
set -euo pipefail
fail() { echo "Error: $*" >&2; exit 1; }

# Shared with setup.sh so registration probes and installation always agree.
# An empty instance preserves the original Miora installation exactly.
configure_instance() {
  REVIEW_INSTANCE="${REVIEW_INSTANCE:-}"
  [[ -z "$REVIEW_INSTANCE" || "$REVIEW_INSTANCE" =~ ^[a-z][a-z0-9-]{0,15}$ ]] \
    || fail "invalid REVIEW_INSTANCE: use 1-16 lowercase letters/digits/hyphens, starting with a letter"
  local suffix="${REVIEW_INSTANCE:+-$REVIEW_INSTANCE}"
  STATE_NAME="code-review-runner${suffix}"
  RUNNER_USER="review-runner${suffix}"
  BASE="/opt/${STATE_NAME}"
  RUNNER_DIR="$BASE/runner"
  RUNNER_HOME="/var/lib/${STATE_NAME}"
  SERVICE_NAME="${STATE_NAME}.service"
  SERVICE="/etc/systemd/system/${SERVICE_NAME}"
  REVIEW_RUNNER_NAME="${REVIEW_RUNNER_NAME:-server-code-review${suffix}}"
  RUNNER_LABELS="code-review,rtx3090${REVIEW_INSTANCE:+,code-review-$REVIEW_INSTANCE}"
}

check_registration() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
# The .NET runner writes UTF-8 registration metadata with a BOM.
data = json.load(open(sys.argv[1], encoding='utf-8-sig'))
if data.get('gitHubUrl', '').rstrip('/').lower() != sys.argv[2].lower() or data.get('agentName') != sys.argv[3]:
    sys.exit('Error: existing runner has a different scope/name; unregister it explicitly first')
PY
}

replace_runner_files() {
  local source="$1" destination="$2"
  # Remove only replaceable binaries; retain registration, credentials and jobs.
  rm -rf -- "${destination:?}/bin" "${destination:?}/externals"
  # The runner owns this destination: unlink existing files instead of opening
  # through links that could redirect this root copy outside the runner tree.
  cp -a --remove-destination "$source/." "$destination/"
}

main() {
MODE="${1:-install}"
[[ $# -le 1 ]] || fail "expected at most one argument"
case "$MODE" in
  install|--dry-run) ;;
  --help|-h) echo "Usage: $0 [--dry-run]; REVIEW_GITHUB_URL is required (see README.md)"; exit 0 ;;
  *) fail "unknown argument: $MODE" ;;
esac

REVIEW_GITHUB_URL="${REVIEW_GITHUB_URL:-}"
configure_instance
REVIEW_RUNNER_VERSION="${REVIEW_RUNNER_VERSION:-2.337.0}"
if [[ -z "${REVIEW_RUNNER_SHA256:-}" && "$REVIEW_RUNNER_VERSION" == 2.337.0 ]]; then
  REVIEW_RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
fi
REVIEW_OLLAMA_PORT="${REVIEW_OLLAMA_PORT:-11434}"
[[ "$REVIEW_GITHUB_URL" =~ ^https://github\.com/[a-zA-Z0-9_-]+(/[a-zA-Z0-9_.-]+)?$ ]] \
  || fail "REVIEW_GITHUB_URL must be https://github.com/ORG or https://github.com/OWNER/REPO"
[[ "$REVIEW_RUNNER_NAME" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || fail "invalid REVIEW_RUNNER_NAME"
[[ "$REVIEW_RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "pin an explicit REVIEW_RUNNER_VERSION"
[[ "${REVIEW_RUNNER_SHA256:-}" =~ ^[a-f0-9]{64}$ ]] || fail "REVIEW_RUNNER_SHA256 is required for this version"
if [[ ! "$REVIEW_OLLAMA_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( REVIEW_OLLAMA_PORT > 65535 )); then
  fail "invalid REVIEW_OLLAMA_PORT"
fi
MARKER='# Managed by external/cawser/code-review-runner/install.sh'
render_service() {
  cat <<EOF
$MARKER
[Unit]
Description=GitHub runner for local model code reviews
Wants=network-online.target
After=network-online.target ollama.service

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Environment=HOME=${RUNNER_HOME}
Environment=RUNNER_TOOL_CACHE=${RUNNER_HOME}/tool-cache
StateDirectory=${STATE_NAME}
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
KillMode=control-group
UMask=0077
NoNewPrivileges=true
RestrictSUIDSGID=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${RUNNER_DIR}

[Install]
WantedBy=multi-user.target
EOF
}
if [[ "$MODE" == --dry-run ]]; then
  echo "GitHub scope: ${REVIEW_GITHUB_URL}; runner: ${REVIEW_RUNNER_NAME}"
  echo "Runner ${REVIEW_RUNNER_VERSION}; SHA256 ${REVIEW_RUNNER_SHA256}"
  echo "Labels: self-hosted,linux,x64,${RUNNER_LABELS}"
  echo "Service: ${SERVICE}"
  echo "Executor: Claude Code + Ollama, installed per job by the reusable workflow"
  echo "Ollama API: http://127.0.0.1:${REVIEW_OLLAMA_PORT}"
  render_service
  exit 0
fi

REVIEW_RUNNER_TOKEN="${REVIEW_RUNNER_TOKEN:-}"
if [[ -n "${REMOTE_HOST:-}" ]]; then
  {
    for key in REVIEW_INSTANCE REVIEW_GITHUB_URL REVIEW_RUNNER_NAME REVIEW_RUNNER_VERSION REVIEW_RUNNER_SHA256 \
      REVIEW_OLLAMA_PORT REVIEW_RUNNER_TOKEN; do
      printf 'export %s=%q\n' "$key" "${!key}"
    done
    cat "$0"
  } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" sudo -n bash -s
  exit $?
fi

[[ "$EUID" -eq 0 ]] || fail "run as root or use setup.sh / REMOTE_HOST"
umask 022
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail "requires Linux x86_64"
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || fail "this installer targets Debian 13"
systemctl is-active --quiet ollama.service || fail "native Ollama must be running first"
curl -fsS --max-time 5 "http://127.0.0.1:${REVIEW_OLLAMA_PORT}/api/version" >/dev/null \
  || fail "Ollama API is unavailable"
exec 9>/run/lock/code-review-runner-install.lock
flock -n 9 || fail "another review runner installation is in progress"
if [[ -d "$BASE" ]]; then
  [[ -f "$BASE/.managed" ]] || fail "${BASE} belongs to an unmanaged installation"
elif id "$RUNNER_USER" >/dev/null 2>&1; then
  fail "${RUNNER_USER} user already exists without a managed installation"
fi
EXISTING_UNIT="$(systemctl show "$SERVICE_NAME" -p FragmentPath --value)"
if [[ -n "$EXISTING_UNIT" ]]; then
  if [[ "$EXISTING_UNIT" != "$SERVICE" ]] || ! grep -Fxq "$MARKER" "$SERVICE"; then
    fail "an unmanaged ${SERVICE_NAME} already exists"
  fi
fi
if id "$RUNNER_USER" >/dev/null 2>&1; then
  for group in $(id -nG "$RUNNER_USER"); do
    case "$group" in sudo|wheel|docker|root) fail "${RUNNER_USER} must not belong to ${group}" ;; esac
  done
fi
if [[ -f "$RUNNER_DIR/.runner" ]]; then
  # .runner is registration metadata, not .credentials. Refuse changing scope
  # or identity on a rerun; never use --replace to evict another runner.
  check_registration "$RUNNER_DIR/.runner" "$REVIEW_GITHUB_URL" "$REVIEW_RUNNER_NAME"
elif [[ -z "$REVIEW_RUNNER_TOKEN" ]]; then
  fail "REVIEW_RUNNER_TOKEN is required for initial registration; setup.sh can obtain it through gh"
fi

echo '==> Installing native runner prerequisites...'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  curl ca-certificates git gh python3 libicu76 libssl3t64 zlib1g libkrb5-3 liblttng-ust1t64 libunwind8
install -d -m 0755 "$BASE"
touch "$BASE/.managed"
WORK="$(mktemp -d "$BASE/.install.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$RUNNER_HOME" --no-create-home \
    --shell /usr/sbin/nologin "$RUNNER_USER"
fi
install -d -m 0700 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_HOME" "$RUNNER_DIR"
CHANGED=0
INSTALLED="$(cat "$BASE/.runner-sha256" 2>/dev/null || true)"
if [[ "$INSTALLED" != "$REVIEW_RUNNER_SHA256" || ! -x "$RUNNER_DIR/bin/Runner.Listener" ]]; then
  URL="https://github.com/actions/runner/releases/download/v${REVIEW_RUNNER_VERSION}/actions-runner-linux-x64-${REVIEW_RUNNER_VERSION}.tar.gz"
  curl -fL --retry 3 --connect-timeout 15 --max-time 1800 "$URL" -o "$WORK/runner.tar.gz"
  printf '%s  %s\n' "$REVIEW_RUNNER_SHA256" "$WORK/runner.tar.gz" | sha256sum -c -
  mkdir "$WORK/runner"
  tar -xzf "$WORK/runner.tar.gz" -C "$WORK/runner"
  [[ -x "$WORK/runner/bin/Runner.Listener" ]] || fail "invalid runner archive"
  if [[ -n "$EXISTING_UNIT" ]]; then systemctl stop "$SERVICE_NAME"; fi
  replace_runner_files "$WORK/runner" "$RUNNER_DIR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  printf '%s\n' "$REVIEW_RUNNER_SHA256" > "$BASE/.runner-sha256"
  CHANGED=1
fi

if [[ ! -f "$RUNNER_DIR/.runner" ]]; then
  echo "==> Registering ${REVIEW_RUNNER_NAME} in ${REVIEW_GITHUB_URL}..."
  # Pass the short-lived registration token through the environment, not argv.
  export ACTIONS_RUNNER_INPUT_TOKEN="$REVIEW_RUNNER_TOKEN"
  (
    cd "$RUNNER_DIR"
    runuser -u "$RUNNER_USER" -- ./config.sh --unattended --disableupdate \
      --url "$REVIEW_GITHUB_URL" --name "$REVIEW_RUNNER_NAME" \
      --labels "$RUNNER_LABELS" --work _work
  )
  unset ACTIONS_RUNNER_INPUT_TOKEN REVIEW_RUNNER_TOKEN
fi
render_service > "$WORK/runner.service"
if ! cmp -s "$WORK/runner.service" "$SERVICE"; then
  install -m 0644 "$WORK/runner.service" "$SERVICE"
  CHANGED=1
fi
systemctl daemon-reload
systemctl enable --quiet "$SERVICE_NAME"
if (( CHANGED )); then systemctl restart "$SERVICE_NAME"; else systemctl start "$SERVICE_NAME"; fi
systemctl is-active --quiet "$SERVICE_NAME" || fail "runner service did not start"
echo '==> Runner service started. Confirm it is online in GitHub Settings > Actions > Runners.'
echo '==> Copy the example workflow only into the repositories selected for local reviews.'
}

# Also execute when piped into sudo bash -s (BASH_SOURCE is then empty).
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
