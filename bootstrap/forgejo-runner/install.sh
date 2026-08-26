#!/usr/bin/env bash
# Runs on the gh-runners VM (vmid 117) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.50 ./install.sh
#
# Registers a Forgejo act_runner ALONGSIDE the existing GitHub Actions runners.
#
# This script must never touch /opt/actions-runner or the gh-runner@* units. The
# two CIs coexist as independent systemd services on one Docker host, which is
# also what lets the Forgejo runner reuse the layer cache the GitHub runners
# have already warmed.
#
# Design and runbook: bootstrap/forgejo/README.md
#
# Required env vars:
#   FORGEJO_URL           - e.g. https://forgejo.internal.prakash.com.br
#   FORGEJO_RUNNER_TOKEN  - registration token from Site Admin → Actions → Runners
#
# Optional env vars:
#   RUNNER_IMAGE_VERSION  - act_runner image tag (default: 13.0.0)
#   RUNNER_NAME           - default: homeserver-117
#   RUNNER_LABELS         - default: docker:docker://node:22-bookworm
#   RUNNER_CAPACITY       - concurrent jobs (default: 2)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      FORGEJO_URL          "${FORGEJO_URL:-}" \
      FORGEJO_RUNNER_TOKEN "${FORGEJO_RUNNER_TOKEN:-}" \
      RUNNER_IMAGE_VERSION "${RUNNER_IMAGE_VERSION:-}" \
      RUNNER_NAME          "${RUNNER_NAME:-}" \
      RUNNER_LABELS        "${RUNNER_LABELS:-}" \
      RUNNER_CAPACITY      "${RUNNER_CAPACITY:-}"
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

RUNNER_IMAGE_VERSION="${RUNNER_IMAGE_VERSION:-13.0.0}"
RUNNER_NAME="${RUNNER_NAME:-homeserver-117}"
RUNNER_LABELS="${RUNNER_LABELS:-docker:docker://node:22-bookworm}"
RUNNER_CAPACITY="${RUNNER_CAPACITY:-2}"

if ! command -v docker >/dev/null; then
  echo "Error: docker missing. This VM should already have it from bootstrap/gh-runners/install.sh." >&2
  exit 1
fi

if ! grep -q 'homeserver.keep' /usr/local/sbin/gh-runner-docker-prune 2>/dev/null; then
  echo "Error: gh-runner Docker cleanup does not support persistent-container labels." >&2
  echo "       Re-run bootstrap/gh-runners/setup.sh from this branch first." >&2
  exit 1
fi

# Record the GitHub runner count so the end of this script can prove it did not
# disturb them. This is the whole reason the two stacks are kept separate.
GH_RUNNERS_BEFORE="$(systemctl list-units 'gh-runner@*.service' --state=active --no-legend 2>/dev/null | wc -l | tr -d ' ')"
echo "==> GitHub runners active before this run: ${GH_RUNNERS_BEFORE}"

# The official runner image runs as uid/gid 1000 and must create `.runner` in
# this bind mount during registration.
install -d -m 0750 -o 1000 -g 1000 /opt/forgejo-runner/data
DOCKER_GID="$(stat -c %g /var/run/docker.sock)"

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
  # Runner v5+ no longer mounts the Docker socket into job containers unless
  # requested explicitly. Image-building workflows need the host daemon.
  docker_host: automount
  # Rewrite github.com to the matching owner/repository path in Forgejo inside
  # every job container, so git dependencies resolve locally during an outage.
  # forgejo-sync-repos preserves GitHub owner/name paths, therefore replacing
  # just the host is sufficient and works for every mirrored owner.
  #
  # This lives in the environment and NOT in mix.exs on purpose: that manifest
  # is shared with the GitHub CI, where a Forgejo URL would not resolve at all.
  # The difference between the two CIs belongs here, not in versioned code.
  options: >-
    -e GIT_CONFIG_COUNT=2
    -e GIT_CONFIG_KEY_0=url.${FORGEJO_URL%/}/.insteadOf
    -e GIT_CONFIG_VALUE_0=https://github.com/
    -e GIT_CONFIG_KEY_1=url.${FORGEJO_URL%/}/.insteadOf
    -e GIT_CONFIG_VALUE_1=git@github.com:
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
    labels:
      # bootstrap/gh-runners' stale-container reaper preserves this container.
      homeserver.keep: "true"
    working_dir: /data
    group_add:
      # Allow uid 1000 in the runner image to talk to the host Docker daemon.
      - "${DOCKER_GID}"
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
GH_RUNNERS_AFTER="$(systemctl list-units 'gh-runner@*.service' --state=active --no-legend 2>/dev/null | wc -l | tr -d ' ')"
echo "==> GitHub runners active after this run:  ${GH_RUNNERS_AFTER}"
if [[ "$GH_RUNNERS_AFTER" -lt "$GH_RUNNERS_BEFORE" ]]; then
  echo "Error: GitHub runner count dropped from ${GH_RUNNERS_BEFORE} to ${GH_RUNNERS_AFTER}." >&2
  echo "       This script must not disturb them — investigate before proceeding." >&2
  exit 1
fi

echo ""
echo "✓ Forgejo runner active. GitHub runners untouched (${GH_RUNNERS_AFTER} active)."
