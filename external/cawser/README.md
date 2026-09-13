# Cawser code review server

This deployment belongs to the external machine `camilo@192.168.0.107`
(`server`, Debian 13, NVIDIA RTX 3090 24 GB). It is separate from the homeserver's
Proxmox VMs, Kubernetes applications and general-purpose runners.

Dedicated GitHub runner instances are registered for
[`Cawser/miora`](https://github.com/Cawser/miora) and
[`prem-prakash/werify`](https://github.com/prem-prakash/werify). Local review
workflows are currently paused in both repositories. The registered runners
share native Ollama over `127.0.0.1:11434`, with models stored on the mounted
`/dados` disk.

## Components

- [Ollama](ollama/README.md): pinned native binaries/model, systemd service and GPU check.
- [Review runner](code-review-runner/README.md): dedicated account and GitHub registration; Claude Code is installed per job.
- [Workflow example](code-review-runner/examples/local-code-review.yml): copy into the target repository to enable PR reviews.

## Run from this repository's root

```bash
# Offline previews:
./external/cawser/ollama/setup.sh --dry-run
REVIEW_GITHUB_URL=https://github.com/Cawser/miora \
  ./external/cawser/code-review-runner/setup.sh --dry-run
REVIEW_INSTANCE=werify REVIEW_GITHUB_URL=https://github.com/prem-prakash/werify \
  ./external/cawser/code-review-runner/setup.sh --dry-run

# Install in order:
./external/cawser/ollama/setup.sh
REVIEW_GITHUB_URL=https://github.com/Cawser/miora \
  ./external/cawser/code-review-runner/setup.sh
REVIEW_INSTANCE=werify REVIEW_GITHUB_URL=https://github.com/prem-prakash/werify \
  ./external/cawser/code-review-runner/setup.sh
```

The setup scripts use SSH and passwordless sudo on this external host. Runner
registration uses local `gh` authentication to obtain a short-lived token.
The installers preserve their managed state on re-runs; see each component's
README for version changes, prerequisites and validation commands.
