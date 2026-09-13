# Dedicated local code review runner

Native GitHub Actions runner for the external RTX 3090 host. Claude Code and
pr-tools are installed per job by the Ollama workflow from `Cawser/ai-tooling`.

## Install or update

Use this after [the native Ollama bootstrap](../ollama/README.md). The target
must be Debian 13 x86_64 with passwordless sudo and Ollama listening on loopback.
The local machine needs Bash, SSH and authenticated `gh` for first registration.

```bash
REVIEW_GITHUB_URL=https://github.com/Cawser/miora \
  ./external/cawser/code-review-runner/setup.sh --dry-run
REVIEW_GITHUB_URL=https://github.com/Cawser/miora \
  ./external/cawser/code-review-runner/setup.sh
```

The preview is offline and never prints registration tokens. Setup obtains a
short-lived registration token only when `.runner` is absent. Re-runs preserve
registration and refuse a different repository or runner name. No personal
GitHub token or App private key is copied to the host.

| Variable | Default |
| --- | --- |
| `REVIEW_SSH` | `camilo@192.168.0.107` |
| `REVIEW_GITHUB_URL` | Required organization or repository URL |
| `REVIEW_INSTANCE` | Empty for Miora; `werify` selects the separate existing instance |
| `REVIEW_RUNNER_NAME` | `server-code-review`, with the instance suffix when present |
| `REVIEW_RUNNER_VERSION` | `2.337.0` |
| `REVIEW_RUNNER_SHA256` | Pinned for the default version; required for another version |
| `REVIEW_OLLAMA_PORT` | `11434`, matching the workflow's fixed loopback endpoint |

The runner version is checksum-verified and auto-update is disabled. Update the
version and checksum before GitHub stops accepting an old release. Apply updates
while the selected runner is idle. OS dependencies come from Debian packages,
including `gh` and Python 3; no managed Python distribution or uv is needed.

The service uses `review-runner`, has no sudo/Docker access, and retains its
filesystem restrictions. The installer does not modify other application/CI
runners. A persistent account is not an ephemeral VM sandbox: the review workflow
checks out PR contents for inspection and instructs the model not to execute
project code or install project dependencies.

## Installed layout

```text
/opt/code-review-runner/
  .managed
  .runner-sha256
  runner/                     # binaries, registration, credentials and work area
/var/lib/code-review-runner/   # runner home and per-job tool cache
/etc/systemd/system/code-review-runner.service
```

Named instances add their suffix to the account, service, `/opt` directory and
home. They also receive `code-review-<instance>` as a scheduling label. Local
review workflows in Miora and Werify are currently paused; their runner
registrations remain available for future evaluation.

## Workflow and model

Use [the Miora caller](examples/local-code-review.yml). It follows the merged
`main` of `Cawser/ai-tooling`; that reusable workflow checks out its own exact SHA
for both the existing review skill and helper scripts. Changes originate in the
central ai-tooling checkout and reach organization repositories through
`scripts/push-all.sh`. Its GitHub App needs
contents access to `Cawser/ai-tooling`. The caller passes the existing App ID and
private-key secrets, and needs no Anthropic credential or Claude subscription.

Prepare `qwen3.5-review:9b` with the 64K Modelfile from
[Cawser/ai-tooling](https://github.com/Cawser/ai-tooling/tree/main/examples/ollama-review).
The workflow preflight checks local-only inference, tool support and context.
The alias and its base model must already exist; the runner installer does not
select, replace or download inference models. The current 9B profile is
experimental and has repeated oversized reads in real PRs. The completion and
quality gates must pass before publishing an advisory review.

The runner connects outbound to GitHub over HTTPS. Ollama stays at
`127.0.0.1:11434`; no public port forwarding is needed. The accounts share the
same native Ollama and GPU. Keep this review optional while evaluating it.

## Checks

```bash
python3 -B -m unittest discover -s external/cawser/code-review-runner -p '*_test.py'
shellcheck external/cawser/code-review-runner/{install,setup}.sh
bash -n external/cawser/code-review-runner/install.sh
bash -n external/cawser/code-review-runner/setup.sh
```

On the host, inspect `systemctl status code-review-runner` and
`journalctl -u code-review-runner -f`. Also verify **Online** in GitHub's runner
settings; an active systemd process alone does not prove registration is healthy.
