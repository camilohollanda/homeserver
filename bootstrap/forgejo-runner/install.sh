#!/usr/bin/env bash
# Runs on the gh-runners VM (vmid 117) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.50 ./install.sh
#
# Registers a Forgejo act_runner ALONGSIDE the existing GitHub Actions runners.
#
# This script must never touch /opt/actions-runner or the runner@* units. The
# two CIs coexist as independent systemd services on one Docker host, which is
# also what lets the Forgejo runner reuse the layer cache the GitHub runners
# have already warmed.
#
# Spec: docs/superpowers/specs/2026-08-06-forgejo-actions-design.md
#
# Required env vars:
#   FORGEJO_URL           - e.g. https://forgejo.internal.prakash.com.br
#   FORGEJO_RUNNER_TOKEN  - registration token from Site Admin → Actions → Runners
#
# Optional env vars:
#   RUNNER_IMAGE_VERSION  - act_runner image tag (default: 9.0.1)
#   RUNNER_NAME           - default: homeserver-117
#   RUNNER_LABELS         - default: docker:docker://node:22-bookworm
#   RUNNER_CAPACITY       - concurrent jobs (default: 2)
#   MIRROR_PREFIX         - Forgejo owner holding the GitHub mirrors (default: mirrors)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      FORGEJO_URL          "${FORGEJO_URL:-}" \
      FORGEJO_RUNNER_TOKEN "${FORGEJO_RUNNER_TOKEN:-}" \
      RUNNER_IMAGE_VERSION "${RUNNER_IMAGE_VERSION:-}" \
      RUNNER_NAME          "${RUNNER_NAME:-}" \
      RUNNER_LABELS        "${RUNNER_LABELS:-}" \
      RUNNER_CAPACITY      "${RUNNER_CAPACITY:-}" \
      MIRROR_PREFIX        "${MIRROR_PREFIX:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

: "${FORGEJO_URL:?must be set}"
: "${FORGEJO_RUNNER_TOKEN:?must be set}"

RUNNER_IMAGE_VERSION="${RUNNER_IMAGE_VERSION:-9.0.1}"
RUNNER_NAME="${RUNNER_NAME:-homeserver-117}"
RUNNER_LABELS="${RUNNER_LABELS:-docker:docker://node:22-bookworm}"
RUNNER_CAPACITY="${RUNNER_CAPACITY:-2}"
MIRROR_PREFIX="${MIRROR_PREFIX:-mirrors}"

if ! command -v docker >/dev/null; then
  echo "Error: docker missing. This VM should already have it from bootstrap/gh-runners/install.sh." >&2
  exit 1
fi

# Record the GitHub runner count so the end of this script can prove it did not
# disturb them. This is the whole reason the two stacks are kept separate.
GH_RUNNERS_BEFORE="$(systemctl list-units 'runner@*' --state=active --no-legend 2>/dev/null | wc -l | tr -d ' ')"
echo "==> GitHub runners active before this run: ${GH_RUNNERS_BEFORE}"

mkdir -p /opt/forgejo-runner/data

cat > /opt/forgejo-runner/data/config.yml <<YML
log:
  level: info
runner:
  file: /data/.runner
  capacity: ${RUNNER_CAPACITY}
  timeout: 3h
  labels:
    - ${RUNNER_LABELS}
container:
  network: bridge
  # Rewrite github.com to the local Forgejo mirrors inside every job container,
  # so the git: deps in mix.exs (heroicons, flowbite-icons, baileys_ex) resolve
  # locally during an outage.
  #
  # This lives in the environment and NOT in mix.exs on purpose: that manifest
  # is shared with the GitHub CI, where a Forgejo URL would not resolve at all.
  # The difference between the two CIs belongs here, not in versioned code.
  options: >-
    -e GIT_CONFIG_COUNT=1
    -e GIT_CONFIG_KEY_0=url.${FORGEJO_URL%/}/${MIRROR_PREFIX}/.insteadOf
    -e GIT_CONFIG_VALUE_0=https://github.com/
YML

# .runner is the state file act_runner writes on a successful registration —
# its presence is the idempotency check.
if [[ ! -f /opt/forgejo-runner/data/.runner ]]; then
  echo "==> Registering runner with ${FORGEJO_URL}..."
  docker run --rm \
    -v /opt/forgejo-runner/data:/data \
    "code.forgejo.org/forgejo/runner:${RUNNER_IMAGE_VERSION}" \
    forgejo-runner register --no-interactive \
      --instance "${FORGEJO_URL}" \
      --token "${FORGEJO_RUNNER_TOKEN}" \
      --name "${RUNNER_NAME}" \
      --labels "${RUNNER_LABELS}"
else
  echo "==> Runner already registered — skipping."
fi

cat > /opt/forgejo-runner/docker-compose.yml <<COMPOSE
services:
  runner:
    image: code.forgejo.org/forgejo/runner:${RUNNER_IMAGE_VERSION}
    container_name: forgejo-runner
    restart: unless-stopped
    working_dir: /data
    volumes:
      - /opt/forgejo-runner/data:/data
      # Host Docker socket: jobs run as sibling containers and reuse the layer
      # cache the GitHub runners already warmed on this VM.
      - /var/run/docker.sock:/var/run/docker.sock
    command: forgejo-runner daemon --config /data/config.yml
COMPOSE

cat > /etc/systemd/system/forgejo-runner.service <<'SVC'
[Unit]
Description=Forgejo Actions runner (coexists with the GitHub Actions runners)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/forgejo-runner
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable -q forgejo-runner
if systemctl is-active --quiet forgejo-runner; then
  systemctl restart forgejo-runner
else
  systemctl start forgejo-runner
fi

# Assert we left the GitHub CI alone. A drop here means this script damaged the
# existing setup, which is worse than the Forgejo runner failing to start.
GH_RUNNERS_AFTER="$(systemctl list-units 'runner@*' --state=active --no-legend 2>/dev/null | wc -l | tr -d ' ')"
echo "==> GitHub runners active after this run:  ${GH_RUNNERS_AFTER}"
if [[ "$GH_RUNNERS_AFTER" -lt "$GH_RUNNERS_BEFORE" ]]; then
  echo "Error: GitHub runner count dropped from ${GH_RUNNERS_BEFORE} to ${GH_RUNNERS_AFTER}." >&2
  echo "       This script must not disturb them — investigate before proceeding." >&2
  exit 1
fi

echo ""
echo "✓ Forgejo runner active. GitHub runners untouched (${GH_RUNNERS_AFTER} active)."
