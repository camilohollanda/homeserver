#!/usr/bin/env bash
# Runs on the gh-runners VM (vmid 117) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.50 ./install.sh
#
# Provisions ephemeral, JIT-registered GitHub Actions runners. Each instance
# picks up exactly one job from its assigned org's runner pool, then systemd
# restarts it with a fresh JIT config (no state between jobs).
#
# Required env vars:
#   GH_APP_CLIENT_ID         - GitHub App Client ID (preferred) or numeric App ID — used as the JWT `iss` claim
#   GH_APP_PRIVATE_KEY       - PEM contents of the App's private key (with newlines)
#   GH_ORGS                  - Comma-separated org list, each entry `org` or
#                              `org:count` (e.g. "iddh-com-br:2,prem-prakash:12").
#                              A bare org falls back to RUNNERS_PER_ORG.
#
# The App's per-org installation is auto-discovered at runtime via
# GET /orgs/{org}/installation. The App must be installed on every org in
# GH_ORGS with the "Self-hosted runners: Read & write" org permission.
#
# Optional env vars:
#   RUNNERS_PER_ORG          - Default slots for orgs listed without `:count`
#                              (default: 4). Orgs are not equally busy — one
#                              repo's PR opens 3 jobs at once (checks, sidecar,
#                              review), so a flat count either starves the busy
#                              org or parks idle runners on the quiet one.
#                              Prefer per-org counts in GH_ORGS.
#   RUNNER_VERSION           - actions/runner release version (default: 2.336.0)
#                              GitHub hard-blocks deprecated runner versions: the
#                              runner still connects and reaches "Listening for
#                              Jobs", then the broker rejects it with "Runner
#                              version vX is deprecated and cannot receive
#                              messages" and it exits. With Restart=always that
#                              looks like a crash-loop, not an upgrade prompt.
#                              Keep this near the latest actions/runner release.
#   RUNNER_LABELS            - Comma-separated labels (default: "self-hosted,linux,homeserver")
#   RUNNER_ERL_FLAGS         - ERL_FLAGS handed to every job (default: "+S 4:4").
#                              The BEAM sizes its scheduler pool from the host's
#                              core count, so an unconstrained `mix test` opens
#                              one scheduler per core and a single job saturates
#                              the box. Capping schedulers costs a little
#                              wall-clock per job and buys back concurrency
#                              across jobs. Set empty to leave the BEAM alone.
#   ACTIONS_RESULTS_URL      - Self-hosted cache server URL (must end with /).
#                              When set, every runner binary is patched so it
#                              doesn't overwrite this value at job start, and
#                              the URL is injected into each instance's env.
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      GH_APP_CLIENT_ID         "${GH_APP_CLIENT_ID:-}" \
      GH_APP_PRIVATE_KEY       "${GH_APP_PRIVATE_KEY:-}" \
      GH_ORGS                  "${GH_ORGS:-}" \
      RUNNERS_PER_ORG          "${RUNNERS_PER_ORG:-}" \
      RUNNER_VERSION           "${RUNNER_VERSION:-}" \
      RUNNER_LABELS            "${RUNNER_LABELS:-}" \
      RUNNER_ERL_FLAGS         "${RUNNER_ERL_FLAGS-+S 4:4}" \
      ACTIONS_RESULTS_URL      "${ACTIONS_RESULTS_URL:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

: "${GH_APP_CLIENT_ID:?must be set}"
: "${GH_APP_PRIVATE_KEY:?must be set}"
: "${GH_ORGS:?must be set}"

RUNNERS_PER_ORG="${RUNNERS_PER_ORG:-4}"
RUNNER_VERSION="${RUNNER_VERSION:-2.336.0}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,homeserver}"
# Unset-only default (`-`, not `:-`): an explicitly empty value is a request to
# leave the BEAM unconstrained, and the remote-exec block above always exports
# this var, so `:-` would silently override that opt-out on remote runs.
RUNNER_ERL_FLAGS="${RUNNER_ERL_FLAGS-+S 4:4}"
ACTIONS_RESULTS_URL="${ACTIONS_RESULTS_URL:-}"

# Cache-server URL must end with a slash per falcondev docs; tolerate either form.
if [[ -n "$ACTIONS_RESULTS_URL" && "${ACTIONS_RESULTS_URL: -1}" != "/" ]]; then
  ACTIONS_RESULTS_URL="${ACTIONS_RESULTS_URL}/"
fi

# Renames the env-var lookup ACTIONS_RESULTS_URL → ACTIONS_RESULTS_ORL inside
# Runner.Worker.dll (string is UTF-16LE, hence the \x00 between each ASCII
# byte). Stops the runner from overwriting whatever ACTIONS_RESULTS_URL we
# inject via systemd at job start. Idempotent: sed silently no-ops on
# already-patched binaries. If actions/runner ever ships a build where this
# byte sequence has moved, runs will quietly fall back to GitHub's cache —
# revisit the pattern at https://gha-cache-server.falcondev.io/getting-started
patch_runner_worker_dll() {
  local dll="$1"
  [[ -f "$dll" ]] || return 0
  sed -i 's/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x55\x00\x52\x00\x4C\x00/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x4F\x00\x52\x00\x4C\x00/g' "$dll"
}

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) RUNNER_ARCH=x64 ;;
  arm64) RUNNER_ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

RUNNER_DIR=/opt/actions-runner
INSTANCE_ROOT=/opt/runners
ETC_DIR=/etc/gh-runners

# ---------------------------------------------------------------------------
# Heal a stale docker.list from a prior failed run on the wrong distro.
# Earlier versions of this script hard-coded the Ubuntu URL, so a re-run on
# Debian would explode in `apt-get update` before reaching the Docker block.
# ---------------------------------------------------------------------------
. /etc/os-release
if [[ -f /etc/apt/sources.list.d/docker.list ]] \
   && ! grep -q "download.docker.com/linux/${ID}" /etc/apt/sources.list.d/docker.list; then
  echo "==> Removing stale docker.list (wrong distro)"
  rm -f /etc/apt/sources.list.d/docker.list
fi

# ---------------------------------------------------------------------------
# Base packages — plus the apt deps werify's pr-checks installs at job time
# (preinstalling saves the apt-get cycle on every PR run; `sudo apt-get`
# still works at workflow time for repos that need other packages).
# ---------------------------------------------------------------------------
echo "==> Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg jq openssl git \
  ffmpeg mediainfo opus-tools mp3info unzip \
  build-essential

# ---------------------------------------------------------------------------
# Docker (engine + buildx + compose plugin)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
  echo "==> Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) DOCKER_DISTRO=ubuntu ;;
    debian) DOCKER_DISTRO=debian ;;
    *) echo "unsupported distro for Docker install: ${ID:-unknown}" >&2; exit 1 ;;
  esac
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# ---------------------------------------------------------------------------
# gh CLI (used by claude.yml's allowed Bash(gh ...) tools)
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null; then
  echo "==> Installing gh CLI..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
fi

# ---------------------------------------------------------------------------
# Rust toolchain — required by Elixir/Rustler-based deps (e.g. baileys_ex).
# System-wide rustup install: shared RUSTUP_HOME/CARGO_HOME with the
# binaries symlinked into /usr/local/bin so they're on the default PATH
# for any user (including `runner`) and any spawn context (including
# systemd-spawned, which doesn't source profile/bashrc).
# ---------------------------------------------------------------------------
if ! command -v cargo >/dev/null; then
  echo "==> Installing Rust toolchain (system-wide via rustup)..."
  apt-get install -y --no-install-recommends pkg-config libssl-dev
  export RUSTUP_HOME=/usr/local/rustup
  export CARGO_HOME=/usr/local/cargo
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path
  # Skip the rustup proxy and symlink the real toolchain binaries directly.
  # The proxy needs RUSTUP_HOME set in the caller's env to find its default
  # toolchain, but systemd-spawned runner jobs don't inherit /etc/profile,
  # so the proxy would error with "no default toolchain configured".
  for bin in cargo rustc rustdoc; do
    src=$(ls /usr/local/rustup/toolchains/stable-*/bin/"$bin" 2>/dev/null | head -1)
    [[ -n "$src" ]] && ln -sf "$src" "/usr/local/bin/${bin}"
  done
  # rustup itself stays at /usr/local/bin pointing at the proxy, for manual
  # toolchain updates (run with RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo).
  ln -sf "${CARGO_HOME}/bin/rustup" "/usr/local/bin/rustup"
fi

# ---------------------------------------------------------------------------
# libicu — required by the .NET-based actions/runner. The upstream
# installdependencies.sh handles Ubuntu and older Debian releases, but
# doesn't recognize newer ones (e.g. Debian 13 trixie), so we install
# whichever libicuNN runtime is current on this host.
# ---------------------------------------------------------------------------
if [[ "${ID:-}" == "debian" ]]; then
  ICU_PKG=$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null \
            | awk '{print $1}' | sort -V | tail -1)
  if [[ -n "${ICU_PKG:-}" ]]; then
    apt-get install -y --no-install-recommends "$ICU_PKG"
  else
    echo "Warning: no libicuNN package found in apt; runner may fail with ICU error" >&2
  fi
fi

# ---------------------------------------------------------------------------
# runner user
# ---------------------------------------------------------------------------
if ! id runner &>/dev/null; then
  echo "==> Creating runner user..."
  useradd -m -s /bin/bash runner
fi
usermod -aG docker runner

# Scoped sudoers: workflows can `sudo apt-get install` for build-time deps.
cat > /etc/sudoers.d/runner <<'SUDO'
runner ALL=(root) NOPASSWD: /usr/bin/apt-get
SUDO
chmod 440 /etc/sudoers.d/runner

# ---------------------------------------------------------------------------
# Shared runner tool cache — setup-beam (and any @actions/tool-cache user)
# installs OTP/Elixir/etc into $RUNNER_TOOL_CACHE, which defaults per-runner
# to <runner-dir>/_work/_tool. Per-instance paths break Dialyzer PLT caches
# across instances because PLTs embed absolute paths to OTP's .beam files.
# Pointing every instance at the same dir means the OTP install lives at one
# absolute path host-wide, so a PLT built on members-1 is valid on members-2.
# Mode 0775 so two concurrent setup-beam runs (same version) don't fight
# over directory creation. @actions/tool-cache uses a `.complete` marker
# file, so the race window is small but non-zero on a cold cache.
# ---------------------------------------------------------------------------
install -d -m 0775 -o runner -g runner /opt/runner-tool-cache

# ---------------------------------------------------------------------------
# actions/runner binary
# Re-extract if RUNNER_VERSION changed (also wipes per-instance copies so they
# get re-created from the new binary).
# ---------------------------------------------------------------------------
RUNNER_VERSION_FILE="${RUNNER_DIR}/.runner-version-installed"
INSTALLED_VERSION="$(cat "$RUNNER_VERSION_FILE" 2>/dev/null || true)"
if [[ "$INSTALLED_VERSION" != "$RUNNER_VERSION" ]]; then
  echo "==> Installing actions/runner ${RUNNER_VERSION} (previous: ${INSTALLED_VERSION:-none})..."
  # Stop any currently-running runners before swapping the binary out from under them.
  if [[ -n "$INSTALLED_VERSION" ]]; then
    systemctl list-units --type=service --no-legend 'gh-runner@*.service' 2>/dev/null \
      | awk '{print $1}' | xargs -r -n1 systemctl stop || true
    rm -rf "${INSTANCE_ROOT:?}"/*
  fi
  rm -rf "$RUNNER_DIR"
  mkdir -p "$RUNNER_DIR"
  tarball="/tmp/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  curl -fL -o "$tarball" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  tar xzf "$tarball" -C "$RUNNER_DIR"
  rm -f "$tarball"
  if [[ -x "${RUNNER_DIR}/bin/installdependencies.sh" ]]; then
    "${RUNNER_DIR}/bin/installdependencies.sh"
  fi
  echo "$RUNNER_VERSION" > "$RUNNER_VERSION_FILE"
fi

# Patch the source runner's Runner.Worker.dll so per-instance copies inherit
# the patch via `cp -a` below. No-op when ACTIONS_RESULTS_URL is unset (i.e.
# user wants the default GitHub cache behaviour).
if [[ -n "$ACTIONS_RESULTS_URL" ]]; then
  patch_runner_worker_dll "${RUNNER_DIR}/bin/Runner.Worker.dll"
fi

# ---------------------------------------------------------------------------
# Helper scripts in /usr/local/sbin (kept out of /opt/actions-runner so they
# don't get copied into every per-instance dir).
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/gh-runner-app-token <<'TOKEN'
#!/usr/bin/env bash
# Prints a GitHub App installation access token for ORG on stdout.
# Usage: gh-runner-app-token ORG
#
# Auto-discovers the App's installation on the target org, so adding an org
# needs no installation id anywhere in the config.
set -euo pipefail

ORG="${1:?org required}"
CLIENT_ID="${GH_APP_CLIENT_ID:?missing GH_APP_CLIENT_ID}"
PRIVATE_KEY_PATH="${GH_APP_PRIVATE_KEY_PATH:-/etc/gh-runners/private-key.pem}"

[[ -r "$PRIVATE_KEY_PATH" ]] || { echo "cannot read $PRIVATE_KEY_PATH" >&2; exit 1; }

b64url() { base64 -w0 | tr -d '=' | tr '/+' '_-'; }

# 1. App JWT (used to authenticate as the App itself)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
now=$(date +%s)
exp=$((now + 540))   # GitHub max 600s; leave a safety margin
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$now" "$exp" "$CLIENT_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" \
  | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" -binary | b64url)
jwt="${header}.${payload}.${sig}"

gh_api() {
  # gh_api METHOD URL
  curl -fsS -X "$1" \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$2"
}

# 2. Find the App's installation on this org (404 = App not installed there).
inst_lookup=$(gh_api GET "https://api.github.com/orgs/${ORG}/installation" 2>&1) || {
  echo "Installation lookup failed for org ${ORG}." >&2
  echo "Is the GitHub App installed on this org with 'Self-hosted runners: r/w'?" >&2
  echo "Response: $inst_lookup" >&2
  exit 1
}
installation_id=$(printf '%s' "$inst_lookup" | jq -r .id)
[[ -n "$installation_id" && "$installation_id" != "null" ]] || {
  echo "Could not extract installation id: $inst_lookup" >&2; exit 1; }

# 3. Exchange the App JWT for an installation access token.
inst_resp=$(gh_api POST "https://api.github.com/app/installations/${installation_id}/access_tokens")
inst_token=$(printf '%s' "$inst_resp" | jq -r .token)
[[ -n "$inst_token" && "$inst_token" != "null" ]] || {
  echo "installation token failed: $inst_resp" >&2; exit 1; }

printf '%s' "$inst_token"
TOKEN
chmod 755 /usr/local/sbin/gh-runner-app-token

cat > /usr/local/sbin/gh-runner-mint-jit <<'MINT'
#!/usr/bin/env bash
# Mints an ephemeral JIT runner config for ORG and prints it on stdout.
# Usage: gh-runner-mint-jit ORG INSTANCE_NAME
#
# Runner registers into the org's Default runner group (id 1) — the only
# group available on the free plan.
set -euo pipefail

ORG="$1"
INSTANCE_NAME="$2"
LABELS_CSV="${RUNNER_LABELS:-self-hosted,linux,homeserver}"

inst_token=$(/usr/local/sbin/gh-runner-app-token "$ORG")

# The `-<epoch>-<pid>` suffix is what gh-runner-reap-registrations reads to age
# out leaked registrations, so keep the shape if you ever rename instances.
labels_json=$(printf '%s' "$LABELS_CSV" | jq -Rc 'split(",")')
runner_name="${INSTANCE_NAME}-$(date +%s)-$$"

jit_resp=$(curl -fsS -X POST \
  -H "Authorization: Bearer ${inst_token}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/orgs/${ORG}/actions/runners/generate-jitconfig" \
  -d "$(jq -nc \
        --arg name "$runner_name" \
        --argjson labels "$labels_json" \
        '{name: $name, runner_group_id: 1, labels: $labels, work_folder: "_work"}')")
encoded=$(printf '%s' "$jit_resp" | jq -r .encoded_jit_config)
[[ -n "$encoded" && "$encoded" != "null" ]] || { echo "jit config failed: $jit_resp" >&2; exit 1; }
printf '%s' "$encoded"
MINT
chmod 755 /usr/local/sbin/gh-runner-mint-jit

cat > /usr/local/sbin/gh-runner-reap-registrations <<'REAP'
#!/usr/bin/env bash
# Deletes leaked runner registrations from every org this host serves.
#
# A JIT runner deregisters itself only when it *completes* a job. Every other
# exit path — the host rebooting, `systemctl stop`, a job cancelled mid-flight,
# a mint that never gets picked up — strands the registration as `offline`
# forever. With Restart=always minting a fresh config every ~10s, they pile up
# fast: this host had accumulated 1096 of them per org before the first reap.
#
# Safety: only registrations whose name matches this host's `<instance>-<epoch>
# -<pid>` shape are touched, and only when the embedded epoch is older than
# REAP_REGISTRATION_AGE_H. That age gate is the important one — a runner that
# has minted a config but hasn't connected yet also reads as `offline`, and
# deleting it would break the job it was about to take.
set -uo pipefail
log() { echo "[reap-registrations] $*"; }

MAX_AGE_H="${REAP_REGISTRATION_AGE_H:-2}"
ETC_DIR=/etc/gh-runners
cutoff=$(( $(date +%s) - MAX_AGE_H * 3600 ))

shopt -s nullglob
mapfile -t ORGS < <(
  for envfile in "${ETC_DIR}"/instances/*.env; do
    sed -n 's/^GH_ORG=//p' "$envfile"
  done | sort -u
)
shopt -u nullglob

[[ ${#ORGS[@]} -gt 0 ]] || { log "no orgs configured; nothing to do"; exit 0; }

for ORG in "${ORGS[@]}"; do
  token=$(/usr/local/sbin/gh-runner-app-token "$ORG") || {
    log "$ORG: could not mint an installation token; skipping"
    continue
  }

  # Collect first, delete second: deleting while paginating shifts every
  # later page and would silently skip half the list.
  stale=()
  page=1
  while :; do
    resp=$(curl -fsS \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${ORG}/actions/runners?per_page=100&page=${page}") || {
      log "$ORG: listing failed on page ${page}; keeping what we have"
      break
    }
    count=$(printf '%s' "$resp" | jq '.runners | length')
    [[ "$count" -gt 0 ]] || break
    while IFS=$'\t' read -r id name; do
      # Trailing `-<epoch>-<pid>`; anything else was registered by some other
      # tool and is none of our business.
      pid_stripped="${name%-*}"
      ts="${pid_stripped##*-}"
      [[ "$ts" =~ ^[0-9]{9,}$ ]] || continue
      (( ts < cutoff )) && stale+=("$id")
    done < <(printf '%s' "$resp" \
             | jq -r '.runners[] | select(.status == "offline") | "\(.id)\t\(.name)"')
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  deleted=0 failed=0
  for id in "${stale[@]:-}"; do
    [[ -n "$id" ]] || continue
    if curl -fsS -o /dev/null -X DELETE \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${ORG}/actions/runners/${id}"; then
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1))
    fi
  done
  log "$ORG: deleted ${deleted} stale registration(s) older than ${MAX_AGE_H}h (${failed} failed)"
done
REAP
chmod 755 /usr/local/sbin/gh-runner-reap-registrations

cat > /etc/systemd/system/gh-runner-reap-registrations.service <<'REAPSVC'
[Unit]
Description=Delete leaked GitHub Actions runner registrations
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/gh-runners/env
ExecStart=/usr/local/sbin/gh-runner-reap-registrations
REAPSVC

cat > /etc/systemd/system/gh-runner-reap-registrations.timer <<'REAPTIMER'
[Unit]
Description=Daily reap of leaked GitHub Actions runner registrations

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
REAPTIMER

cat > /usr/local/sbin/gh-runner-run-instance <<'RUN'
#!/usr/bin/env bash
# systemd ExecStart wrapper. Mints a JIT config for this instance, then
# execs run.sh inside the instance directory — the runner picks up one
# job, exits, and systemd loops us back here.
# Usage: gh-runner-run-instance INSTANCE_NAME
set -euo pipefail
INSTANCE_NAME="${1:?instance name required}"
INSTANCE_DIR="/opt/runners/${INSTANCE_NAME}"
[[ -d "$INSTANCE_DIR" ]] || { echo "missing instance dir: $INSTANCE_DIR" >&2; exit 1; }
: "${GH_ORG:?missing GH_ORG (loaded from /etc/gh-runners/instances/${INSTANCE_NAME}.env)}"
JIT=$(/usr/local/sbin/gh-runner-mint-jit "$GH_ORG" "$INSTANCE_NAME")
cd "$INSTANCE_DIR"
exec ./run.sh --jitconfig "$JIT"
RUN
chmod 755 /usr/local/sbin/gh-runner-run-instance

cat > /usr/local/sbin/gh-runner-clean-workspace <<'CLEANWORK'
#!/usr/bin/env bash
# A JIT runner handles exactly one job. Remove that job's workspace before the
# next registration is minted so checkouts, build outputs and RUNNER_TEMP do
# not accumulate across otherwise-ephemeral runner processes.
set -euo pipefail
INSTANCE_NAME="${1:?instance name required}"
WORK_DIR="/opt/runners/${INSTANCE_NAME}/_work"

[[ -d "/opt/runners/${INSTANCE_NAME}" ]] || {
  echo "missing instance dir: /opt/runners/${INSTANCE_NAME}" >&2
  exit 1
}

if [[ -d "$WORK_DIR" ]]; then
  find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
install -d -m 0755 -o runner -g runner "$WORK_DIR"
CLEANWORK
chmod 755 /usr/local/sbin/gh-runner-clean-workspace

# ---------------------------------------------------------------------------
# Persisted env + private key
# ---------------------------------------------------------------------------
install -d -m 0750 -o root -g runner "$ETC_DIR"
install -d -m 0750 -o root -g runner "$ETC_DIR/instances"

(
  umask 077
  printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$ETC_DIR/private-key.pem"
)
chown root:runner "$ETC_DIR/private-key.pem"
chmod 0640 "$ETC_DIR/private-key.pem"

# ERL_FLAGS is quoted because its value contains a space (`+S 4:4`). systemd
# strips the quotes when reading an EnvironmentFile, and quoting also keeps the
# file safe to `source` from a shell — unquoted, `ERL_FLAGS=+S 4:4` parses as an
# assignment followed by an attempt to run `4:4` as a command.
cat > "$ETC_DIR/env" <<ENVFILE
GH_APP_CLIENT_ID="${GH_APP_CLIENT_ID}"
GH_APP_PRIVATE_KEY_PATH="${ETC_DIR}/private-key.pem"
RUNNER_LABELS="${RUNNER_LABELS}"
ERL_FLAGS="${RUNNER_ERL_FLAGS}"
ACTIONS_RESULTS_URL="${ACTIONS_RESULTS_URL}"
ENVFILE
chown root:runner "$ETC_DIR/env"
chmod 0640 "$ETC_DIR/env"

# ---------------------------------------------------------------------------
# systemd template
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/gh-runner@.service <<'SVC'
[Unit]
Description=GitHub Actions ephemeral runner (%i)
After=network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
User=runner
Group=runner
WorkingDirectory=/opt/runners/%i
# Per-instance BEAM tool state — two runners share the same `runner` user, so
# pointing MIX_HOME/HEX_HOME/REBAR_CACHE_DIR at the instance dir avoids races
# on ~runner/.mix when both run setup-beam concurrently. (One such race left
# an archive with an empty elixir_version in ~runner/.mix/archives, which
# bricks `mix local.rebar` because Mix.start scans archives at boot.)
Environment=MIX_HOME=/opt/runners/%i/.mix
Environment=HEX_HOME=/opt/runners/%i/.hex
Environment=REBAR_CACHE_DIR=/opt/runners/%i/.cache/rebar3
Environment=RUNNER_TOOL_CACHE=/opt/runner-tool-cache
# Carries GH_APP_CLIENT_ID, RUNNER_LABELS, ACTIONS_RESULTS_URL and ERL_FLAGS.
# ERL_FLAGS lands in the job's environment because the runner hands its own
# process env down to every step, so it constrains `mix`/`iex` without any
# workflow-side opt-in.
EnvironmentFile=/etc/gh-runners/env
EnvironmentFile=/etc/gh-runners/instances/%i.env
# Run as root (the `+` prefix) because Docker jobs can leave root-owned files
# in _work. The previous JIT process has exited before systemd reaches this.
ExecStartPre=+/usr/local/sbin/gh-runner-clean-workspace %i
ExecStart=/usr/local/sbin/gh-runner-run-instance %i
Restart=always
RestartSec=10
# Give an in-flight job up to 5 min to wrap before SIGKILL
TimeoutStopSec=5min
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Docker cleanup
# CI jobs use `docker compose up` with images (e.g. postgres) that declare
# anonymous VOLUMEs. `docker compose down` (without -v) preserves those by
# design, so on a long-lived runner host they accumulate forever — ~650
# orphaned anonymous volumes filled the 60G root disk in 10 days.
#
# The previous one-liner (`docker system prune --volumes -f --filter until=24h`)
# was WRONG and silently broke: this engine rejects `until` together with
# `--volumes` ("ERROR: The \"until\" filter is not supported with --volumes")
# and the whole command exits non-zero BEFORE pruning anything — so for weeks
# nothing was reclaimed and 500 anon volumes (35G) refilled the disk.
#
# Fix: a dedicated script that prunes each resource class with the right flags.
# Volume prune runs on its OWN with NO `until` filter (the engine forbids it
# there). It only removes volumes not attached to a container, so an in-flight
# job's postgres is safe. Ordering matters — reap leaked job containers first
# so their anonymous volumes detach before the volume prune runs.
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/gh-runner-docker-prune <<'PRUNE'
#!/usr/bin/env bash
# Reclaim Docker disk on the runners host. Resilient by design: no `set -e`,
# every step guarded with `|| true`, so one failing class never aborts the
# rest (the bug that let the disk fill in the first place).
set -u
log() { echo "[docker-prune] $*"; }

# 1. Reap leaked CI containers. Ephemeral runner jobs finish in minutes, so a
#    container older than REAP_AGE_H hours is an orphaned compose stack from a
#    job that never ran `docker compose down`; its anonymous volume stays
#    pinned (and invisible to volume-prune) until the container is gone.
#    BuildKit containers are treated the same way: an active build is younger
#    than the age gate, while a leaked builder from an interrupted job must not
#    pin its named state volume forever.
REAP_AGE_H="${REAP_AGE_H:-12}"
now="$(date +%s)"
for cid in $(docker ps -aq); do
  name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
  # Long-lived sidecars on this shared Docker host opt out explicitly. The
  # Forgejo act_runner uses this label; without it the age-based CI cleanup
  # would delete its healthy daemon after 12 hours.
  keep="$(docker inspect -f '{{index .Config.Labels "homeserver.keep"}}' "$cid" 2>/dev/null)"
  [ "$keep" = "true" ] && continue
  created="$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null)"
  created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
  [ "$created_epoch" -gt 0 ] || continue
  if [ $(( (now - created_epoch) / 3600 )) -ge "$REAP_AGE_H" ]; then
    log "reaping leaked container ${name:-<unnamed>} ($cid)"
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
done

# 2. Stopped containers, unused images, build cache. `until=24h` IS valid and
#    correct on these (keeps the last day warm for cache hits). `buildx prune`
#    only sees the selected builder; the targeted named-volume pass below is
#    what catches state left by job-scoped builders whose DOCKER_CONFIG is gone.
docker container prune -f --filter until=24h || true
docker image prune -af --filter until=24h || true
docker builder prune -af --filter until=24h || true
docker buildx prune -af --filter until=24h 2>/dev/null || true

# 3. Detached anonymous volumes — NO `until` (engine rejects it). This is the
#    step the old broken command never reached.
docker volume prune -f || true

# 4. setup-buildx names its BuildKit state volumes. Plain `volume prune` keeps
#    named volumes, so job-scoped builders used to leak gigabytes forever after
#    their temporary DOCKER_CONFIG disappeared. Remove only unattached BuildKit
#    state older than the race-safety window; other named volumes are untouched.
BUILDX_VOLUME_AGE_H="${BUILDX_VOLUME_AGE_H:-2}"
for volume in $(docker volume ls --format '{{.Name}}' | grep -E '^buildx_buildkit_.*_state$' || true); do
  [[ -z "$(docker ps -aq --filter "volume=${volume}")" ]] || continue
  created="$(docker volume inspect -f '{{.CreatedAt}}' "$volume" 2>/dev/null)"
  created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
  [[ "$created_epoch" -gt 0 ]] || continue
  if (( (now - created_epoch) / 3600 >= BUILDX_VOLUME_AGE_H )); then
    log "removing detached BuildKit state volume ${volume}"
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
done

log "done; root fs now $(df -h / | awk 'NR==2 {print $5" used, "$4" free"}')"
PRUNE
chmod 755 /usr/local/sbin/gh-runner-docker-prune

cat > /etc/systemd/system/docker-prune.service <<'PRUNESVC'
[Unit]
Description=Prune leaked Docker containers/volumes/images on gh-runners
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gh-runner-docker-prune
PRUNESVC

cat > /etc/systemd/system/docker-prune.timer <<'PRUNETIMER'
[Unit]
Description=Daily Docker cleanup on gh-runners

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
PRUNETIMER

# High-water safety net: a single image build wrote the last 10G in under 30
# minutes during the 2026-08-26 incident. Check every five minutes and prune at
# 70%, leaving enough headroom for one in-flight build. Cheap no-op otherwise.
cat > /etc/systemd/system/docker-prune-highwater.service <<'HWSVC'
[Unit]
Description=Trigger Docker prune when gh-runners root fs reaches 70%
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'u=$(df --output=pcent / | tr -dc 0-9); [ "$u" -ge 70 ] && systemctl start docker-prune.service || true'
HWSVC

cat > /etc/systemd/system/docker-prune-highwater.timer <<'HWTIMER'
[Unit]
Description=Check gh-runners disk high-water every 5 min

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
HWTIMER

systemctl daemon-reload
systemctl enable --now docker-prune.timer docker-prune-highwater.timer \
  gh-runner-reap-registrations.timer

# ---------------------------------------------------------------------------
# Per-org instances
# `install -d -m 0755` (unlike mkdir -p) sets the mode on existing dirs too,
# so this self-heals any prior run that created /opt/runners under a
# restrictive umask.
# ---------------------------------------------------------------------------
install -d -m 0755 "$INSTANCE_ROOT"

IFS=',' read -ra ORGS <<< "$GH_ORGS"
declare -a WANTED_INSTANCES=()
declare -a ORG_SUMMARY=()

for org_spec in "${ORGS[@]}"; do
  ENTRY="$(echo "$org_spec" | xargs)"  # trim
  [[ -z "$ENTRY" ]] && continue

  # Each entry is `org` or `org:count`. Splitting on the first colon keeps bare
  # org names working unchanged, so existing callers don't have to be updated.
  ORG="${ENTRY%%:*}"
  COUNT="${ENTRY#*:}"
  if [[ "$COUNT" == "$ENTRY" ]]; then
    COUNT="$RUNNERS_PER_ORG"
  elif [[ ! "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "  Skipping org spec with a non-positive-integer count: $ENTRY" >&2
    continue
  fi

  if [[ "$ORG" == */* ]]; then
    echo "  Skipping invalid org spec (must be a bare org name, not owner/repo): $ORG" >&2
    continue
  fi
  # Filesystem-safe slug — strip anything outside [A-Za-z0-9._-] just in case
  SLUG="${ORG//[^A-Za-z0-9._-]/-}"
  ORG_SUMMARY+=("${ORG}=${COUNT}")

  for n in $(seq 1 "$COUNT"); do
    INSTANCE="${SLUG}-${n}"
    WANTED_INSTANCES+=("$INSTANCE")
    INSTANCE_DIR="${INSTANCE_ROOT}/${INSTANCE}"
    install -d -m 0755 -o runner -g runner "$INSTANCE_DIR"
    if [[ ! -f "${INSTANCE_DIR}/run.sh" ]]; then
      echo "  Creating instance: $INSTANCE"
      cp -a "${RUNNER_DIR}/." "${INSTANCE_DIR}/"
      chown -R runner:runner "$INSTANCE_DIR"
    fi
    # Idempotently re-patch existing instances too. Newly-copied dirs above
    # inherit the patched source dll already; this catches instances created
    # by older installs that ran before cache-server support landed.
    if [[ -n "$ACTIONS_RESULTS_URL" ]]; then
      patch_runner_worker_dll "${INSTANCE_DIR}/bin/Runner.Worker.dll"
    fi
    cat > "${ETC_DIR}/instances/${INSTANCE}.env" <<ENV
GH_ORG=${ORG}
ENV
    chown root:runner "${ETC_DIR}/instances/${INSTANCE}.env"
    chmod 0640 "${ETC_DIR}/instances/${INSTANCE}.env"
  done
done

if [[ ${#WANTED_INSTANCES[@]} -eq 0 ]]; then
  echo "Error: no valid orgs in GH_ORGS=${GH_ORGS}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Reconcile: enable+start wanted instances, disable+remove orphans
# ---------------------------------------------------------------------------
for INSTANCE in "${WANTED_INSTANCES[@]}"; do
  systemctl enable --now "gh-runner@${INSTANCE}.service"
done

shopt -s nullglob
for envfile in "${ETC_DIR}"/instances/*.env; do
  unit="$(basename "$envfile" .env)"
  keep=false
  for want in "${WANTED_INSTANCES[@]}"; do
    [[ "$unit" == "$want" ]] && { keep=true; break; }
  done
  if ! $keep; then
    echo "  Disabling orphan runner: $unit"
    systemctl disable --now "gh-runner@${unit}.service" 2>/dev/null || true
    rm -f "$envfile"
    rm -rf "${INSTANCE_ROOT}/${unit}"
  fi
done
shopt -u nullglob

echo ""
echo "✓ GitHub Actions runners installed."
echo "  Runners per org:  ${ORG_SUMMARY[*]}  (${#WANTED_INSTANCES[@]} instances total)"
echo "  Labels:           ${RUNNER_LABELS}"
echo "  Runner version:   ${RUNNER_VERSION}"
if [[ -n "$RUNNER_ERL_FLAGS" ]]; then
  echo "  ERL_FLAGS:        ${RUNNER_ERL_FLAGS}"
fi
echo ""
if [[ -n "$ACTIONS_RESULTS_URL" ]]; then
  echo "  Cache server:     ${ACTIONS_RESULTS_URL}  (Runner.Worker.dll patched)"
fi
echo ""
echo "  Status:  systemctl status 'gh-runner@*'"
echo "  Logs:    journalctl -u 'gh-runner@*' -f"
echo "  Runners visible in each org's Settings → Actions → Runners"
