#!/usr/bin/env bash
# Runs on the gh-runners VM (vmid 117) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.50 ./install.sh
#
# Provisions ephemeral, JIT-registered GitHub Actions runners. Each instance
# picks up exactly one job from its assigned repo, then systemd restarts it
# with a fresh JIT config (no state between jobs).
#
# Required env vars:
#   GH_APP_CLIENT_ID         - GitHub App Client ID (preferred) or numeric App ID — used as the JWT `iss` claim
#   GH_APP_PRIVATE_KEY       - PEM contents of the App's private key (with newlines)
#   GH_REPOS                 - Comma-separated owner/repo list (e.g. "iddh-com-br/members,prem-prakash/werify")
#
# The App's per-repo installation is auto-discovered at runtime via
# GET /repos/{owner}/{repo}/installation, so repos can live under any
# account/org the App is installed on.
#
# Optional env vars:
#   RUNNERS_PER_REPO         - Ephemeral runner slots per repo (default: 4)
#   RUNNER_VERSION           - actions/runner release version (default: 2.328.0)
#   RUNNER_LABELS            - Comma-separated labels (default: "self-hosted,linux,homeserver")
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      GH_APP_CLIENT_ID         "${GH_APP_CLIENT_ID:-}" \
      GH_APP_PRIVATE_KEY       "${GH_APP_PRIVATE_KEY:-}" \
      GH_REPOS                 "${GH_REPOS:-}" \
      RUNNERS_PER_REPO         "${RUNNERS_PER_REPO:-}" \
      RUNNER_VERSION           "${RUNNER_VERSION:-}" \
      RUNNER_LABELS            "${RUNNER_LABELS:-}"
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
: "${GH_REPOS:?must be set}"

RUNNERS_PER_REPO="${RUNNERS_PER_REPO:-4}"
RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,homeserver}"

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
# Shared BEAM install dir — workflows can point setup-beam's
# INSTALL_DIR_FOR_OTP / INSTALL_DIR_FOR_ELIXIR at /opt/beam/<lang>-<version>
# so every runner instance writes/reads OTP at the same absolute path.
# Dialyzer PLTs (which embed absolute paths to .beam files) then stay valid
# across instances, so PLT caches can be shared.
# ---------------------------------------------------------------------------
install -d -m 0755 -o runner -g runner /opt/beam

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

# ---------------------------------------------------------------------------
# Helper scripts in /usr/local/sbin (kept out of /opt/actions-runner so they
# don't get copied into every per-instance dir).
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/gh-runner-mint-jit <<'MINT'
#!/usr/bin/env bash
# Mints an ephemeral JIT runner config for OWNER/REPO and prints it on stdout.
# Usage: gh-runner-mint-jit OWNER REPO INSTANCE_NAME
#
# Auto-discovers the App's installation for the target repo so the same
# script works whether the App is installed on an org, a personal account,
# or both — no per-repo installation ID needed.
set -euo pipefail

OWNER="$1"
REPO="$2"
INSTANCE_NAME="$3"

CLIENT_ID="${GH_APP_CLIENT_ID:?missing GH_APP_CLIENT_ID}"
PRIVATE_KEY_PATH="${GH_APP_PRIVATE_KEY_PATH:-/etc/gh-runners/private-key.pem}"
LABELS_CSV="${RUNNER_LABELS:-self-hosted,linux,homeserver}"

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
  # gh_api METHOD URL [BODY]
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${jwt}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body" "$url"
  else
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${jwt}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

# 2. Find the installation for this repo (404 = App not installed there).
inst_lookup=$(gh_api GET "https://api.github.com/repos/${OWNER}/${REPO}/installation" 2>&1) || {
  echo "Installation lookup failed for ${OWNER}/${REPO}." >&2
  echo "Is the GitHub App installed on this repo's account/org?" >&2
  echo "Response: $inst_lookup" >&2
  exit 1
}
installation_id=$(printf '%s' "$inst_lookup" | jq -r .id)
[[ -n "$installation_id" && "$installation_id" != "null" ]] || {
  echo "Could not extract installation id: $inst_lookup" >&2; exit 1; }

# 3. Exchange App JWT for installation access token (scoped to this installation).
inst_resp=$(gh_api POST "https://api.github.com/app/installations/${installation_id}/access_tokens")
inst_token=$(printf '%s' "$inst_resp" | jq -r .token)
[[ -n "$inst_token" && "$inst_token" != "null" ]] || {
  echo "installation token failed: $inst_resp" >&2; exit 1; }

# 4. Mint the JIT runner config (this call uses the installation token, not the App JWT).
labels_json=$(printf '%s' "$LABELS_CSV" | jq -Rc 'split(",")')
runner_name="${INSTANCE_NAME}-$(date +%s)-$$"

jit_resp=$(curl -fsS -X POST \
  -H "Authorization: Bearer ${inst_token}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/generate-jitconfig" \
  -d "$(jq -nc \
        --arg name "$runner_name" \
        --argjson labels "$labels_json" \
        '{name: $name, runner_group_id: 1, labels: $labels, work_folder: "_work"}')")
encoded=$(printf '%s' "$jit_resp" | jq -r .encoded_jit_config)
[[ -n "$encoded" && "$encoded" != "null" ]] || { echo "jit config failed: $jit_resp" >&2; exit 1; }
printf '%s' "$encoded"
MINT
chmod 755 /usr/local/sbin/gh-runner-mint-jit

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
: "${GH_OWNER:?missing GH_OWNER (loaded from /etc/gh-runners/instances/${INSTANCE_NAME}.env)}"
: "${GH_REPO:?missing GH_REPO}"
JIT=$(/usr/local/sbin/gh-runner-mint-jit "$GH_OWNER" "$GH_REPO" "$INSTANCE_NAME")
cd "$INSTANCE_DIR"
exec ./run.sh --jitconfig "$JIT"
RUN
chmod 755 /usr/local/sbin/gh-runner-run-instance

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

cat > "$ETC_DIR/env" <<ENVFILE
GH_APP_CLIENT_ID=${GH_APP_CLIENT_ID}
GH_APP_PRIVATE_KEY_PATH=${ETC_DIR}/private-key.pem
RUNNER_LABELS=${RUNNER_LABELS}
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
EnvironmentFile=/etc/gh-runners/env
EnvironmentFile=/etc/gh-runners/instances/%i.env
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
systemctl daemon-reload

# ---------------------------------------------------------------------------
# Per-repo instances
# `install -d -m 0755` (unlike mkdir -p) sets the mode on existing dirs too,
# so this self-heals any prior run that created /opt/runners under a
# restrictive umask.
# ---------------------------------------------------------------------------
install -d -m 0755 "$INSTANCE_ROOT"

IFS=',' read -ra REPOS <<< "$GH_REPOS"
declare -a WANTED_INSTANCES=()

for repo_spec in "${REPOS[@]}"; do
  repo_spec="$(echo "$repo_spec" | xargs)"  # trim
  [[ -z "$repo_spec" ]] && continue
  if [[ "$repo_spec" != */* ]]; then
    echo "  Skipping invalid repo spec (expected owner/repo): $repo_spec" >&2
    continue
  fi
  OWNER="${repo_spec%/*}"
  REPO="${repo_spec#*/}"
  # Filesystem-safe slug — replace any '/' just in case
  SLUG="${OWNER//\//-}-${REPO//\//-}"

  for n in $(seq 1 "$RUNNERS_PER_REPO"); do
    INSTANCE="${SLUG}-${n}"
    WANTED_INSTANCES+=("$INSTANCE")
    INSTANCE_DIR="${INSTANCE_ROOT}/${INSTANCE}"
    install -d -m 0755 -o runner -g runner "$INSTANCE_DIR"
    if [[ ! -f "${INSTANCE_DIR}/run.sh" ]]; then
      echo "  Creating instance: $INSTANCE"
      cp -a "${RUNNER_DIR}/." "${INSTANCE_DIR}/"
      chown -R runner:runner "$INSTANCE_DIR"
    fi
    cat > "${ETC_DIR}/instances/${INSTANCE}.env" <<ENV
GH_OWNER=${OWNER}
GH_REPO=${REPO}
ENV
    chown root:runner "${ETC_DIR}/instances/${INSTANCE}.env"
    chmod 0640 "${ETC_DIR}/instances/${INSTANCE}.env"
  done
done

if [[ ${#WANTED_INSTANCES[@]} -eq 0 ]]; then
  echo "Error: no valid repos in GH_REPOS=${GH_REPOS}" >&2
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
echo "  Repos:            ${GH_REPOS}"
echo "  Runners per repo: ${RUNNERS_PER_REPO}"
echo "  Labels:           ${RUNNER_LABELS}"
echo "  Runner version:   ${RUNNER_VERSION}"
echo ""
echo "  Status:  systemctl status 'gh-runner@*'"
echo "  Logs:    journalctl -u 'gh-runner@*' -f"
echo "  Runners visible in each repo's Settings → Actions → Runners"
