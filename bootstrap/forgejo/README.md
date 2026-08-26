# Forgejo Actions failover

Forgejo is a warm, LAN-only fallback for GitHub's git hosting, Actions control
plane and container registry. GitHub remains canonical during normal operation.
The Forgejo VM is 119 (`192.168.20.24`); its `act_runner` shares VM 117 with the
ephemeral GitHub runners but is managed by a separate systemd unit.

This is warm failover, not an emergency proxy. Applications must be mirrored,
their Forgejo workflows must have produced images, and the selected Argo CD
Applications must already point at Forgejo before a GitHub outage begins.

The live deployment status, unresolved security decision and exact resumption
checklist are recorded in [FOLLOWUPS.md](FOLLOWUPS.md). Read that handoff before
continuing the rollout.

## Deployment order

1. Apply Terraform to create VM 119 and its internal DNS record.
2. Run `bootstrap/forgejo/setup.sh`.
3. In Forgejo, create the access tokens printed by `setup.sh` and store the
   long-lived values in Infisical project `homeserver`, path `/Forgejo/`.
4. Fill `/etc/forgejo-sync/env` on VM 119, run
   `systemctl start forgejo-sync.service`, and then start
   `forgejo-sync.timer`. The sync token needs permission to create
   organizations and repositories on its first run. The installer enables but
   deliberately leaves this timer stopped while the credential file still has
   placeholder values.
5. Add each repository to `/etc/forgejo-sync/repos` as
   `owner/name private|public`. Keep applications private; public git
   dependencies must be public so isolated Actions job containers can clone
   them after the runner's GitHub-to-Forgejo URL rewrite.
6. Re-run `bootstrap/gh-runners/setup.sh` so Docker cleanup preserves labeled
   persistent containers, then run `bootstrap/forgejo-runner/setup.sh` with the
   site runner registration token.
7. Re-run `bootstrap/k3s/argocd-image-updater-install.sh` so both GHCR and
   Forgejo registries are configured, then let Argo CD sync the new
   ExternalSecrets.
8. Configure and test Forgejo workflows in each application repository.
9. Run `bootstrap/restic/configure.sh forgejo`.
10. Move one staging Application at a time with
    `bootstrap/forgejo/switch-argo-source.sh`.

## Repository synchronization

`forgejo-sync.service` fetches GitHub branches and tags every five minutes and
pushes them to a regular writable Forgejo repository. It never force-pushes.
If commits were pushed directly to Forgejo during an outage, the next sync is
rejected and leaves both sides untouched for deliberate reconciliation.

Remote URLs never contain credentials. Git receives credentials through a
root-only askpass helper, while the source tokens remain in
`/etc/forgejo-sync/env` (`0600`). Repositories absent on the Forgejo side are
created automatically with their original GitHub `owner/name` path.

Suggested initial repository list:

```text
camilohollanda/homeserver private
prem-prakash/werify private
# Add the exact IDDH application repository after confirming its GitHub name.
tailwindlabs/heroicons public
themesberg/flowbite-icons public
```

## Application workflows

Forgejo reads workflows from `.forgejo/workflows/`. The runner installed here
advertises the `docker` label, so jobs use:

```yaml
runs-on: docker
```

Do not point a Forgejo workflow at GHCR or `${{ secrets.GITHUB_TOKEN }}`. The
application repository needs Forgejo Actions secrets for the registry user and
token, and its build must publish to:

```text
forgejo.internal.prakash.com.br/<owner>/<image>
```

Preserve the same immutable and environment tags consumed by
`gitops/argocd-image-updater/image-updater-cr.yaml`. GitHub-only reusable
workflows and permission semantics must be replaced or mirrored before calling
the application failover-ready. The runner mounts the VM 117 Docker socket into
job containers, but the default `node:22-bookworm` execution image does not ship
the Docker CLI; image-building workflows must install it or select a tested CI
image through an additional runner label.

The infrastructure repository includes a small `.forgejo/workflows/validate.yml`
workflow. Its successful execution proves repository sync, workflow discovery,
the runner and the common actions mirror before application CI is enabled.

## Per-application cutover

The switch script changes both the child Argo Application repository URL and
that application's Image Updater registry entry. It checks the Argo repository
credential, Image Updater credential, namespace pull secret, Forgejo health and
the target image before committing anything.

```bash
FORGEJO_REGISTRY_USER=... FORGEJO_REGISTRY_TOKEN=... \
  ./bootstrap/forgejo/switch-argo-source.sh \
  --app werify-staging --to forgejo --dry-run

FORGEJO_REGISTRY_USER=... FORGEJO_REGISTRY_TOKEN=... \
  ./bootstrap/forgejo/switch-argo-source.sh \
  --app werify-staging --to forgejo
```

The root Argo application remains on GitHub. Consequently the cutover commit
must reach GitHub while it is available. Reversal is:

```bash
./bootstrap/forgejo/switch-argo-source.sh --app werify-staging --to github
```

## Backup and recovery

VM 119 snapshots live SQLite with `sqlite3 .backup` at 01:30. The Forgejo restic
profile starts at 02:00 and saves that snapshot, git repositories, `app.ini`,
sync configuration and Let's Encrypt state. OCI registry blobs are excluded
because application workflows can rebuild them.

After restoring the data disk and restic payload, rerun `install.sh`; it keeps
the existing `SECRET_KEY` and `INTERNAL_TOKEN`, preserving sessions and stored
2FA secrets.
