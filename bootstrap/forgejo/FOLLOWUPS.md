# Forgejo rollout handoff

Status captured on 2026-08-26. This document separates what is already live
from manifests and scripts that are only prepared in the branch. Forgejo is
usable as a Git server, but the Actions and Argo failover path is **not ready**.

## Already deployed

- Terraform created VM 119 at `192.168.20.24`, the internal Cloudflare DNS
  record and the Proxmox cloud-init snippet. The final apply reported zero
  infrastructure changes and persisted `forgejo_url` and `forgejo_vm_ip` in
  state.
- Forgejo 16.0.3 is running at
  `https://forgejo.internal.prakash.com.br` with a valid Let's Encrypt
  certificate and SSH on port 2222.
- `/dev/sdb` is mounted as the approximately 200 GB ext4 Forgejo data volume.
- The initial administrator exists. Its credentials were generated during
  bootstrap, but their presence in Infisical has not been verified.
- `forgejo-db-backup.timer` creates a consistent SQLite snapshot before the
  Restic window. The `forgejo` Restic repository was initialized and its first
  encrypted remote snapshot completed successfully.
- VM 117 still has 14 active GitHub runners: two for `iddh-com-br` and twelve
  for `prem-prakash`. Its Docker cleanup now preserves containers labeled
  `homeserver.keep=true`.
- `forgejo-sync.timer` is enabled but intentionally stopped while
  `/etc/forgejo-sync/env` contains placeholder credentials. There are no failed
  systemd units on VM 119.

## Prepared in this branch, not deployed

- Forgejo repository credentials for Argo CD and registry credentials for
  Argo CD Image Updater.
- A dedicated `/Forgejo/` Infisical `ClusterSecretStore` and ExternalSecrets
  for the Argo namespaces and application image-pull secrets.
- Forgejo registry pull credentials on the production and staging Werify,
  IDDH Members and connector Deployments.
- Dual GHCR/Forgejo registry configuration for Argo CD Image Updater.
- A reversible per-application Argo source and image-registry cutover script.
- The Forgejo runner installer and an infrastructure smoke workflow under
  `.forgejo/workflows/`.

Do not assume these resources exist in K3s merely because their manifests are
present here. The root Argo application still follows GitHub `main`, and these
changes have not been synced into the cluster.

## Blocking security decision

The current runner design places `act_runner` on VM 117 and gives both the
runner and its job containers access to `/var/run/docker.sock`. A workflow can
therefore obtain root-equivalent control of VM 117, inspect sibling containers
and potentially compromise the GitHub runner environment on the same host.

Runner registration was deliberately stopped before making this change. Pick
one option explicitly before continuing:

1. Create a dedicated Forgejo runner VM. This is the recommended boundary.
2. Accept the shared-host risk and explicitly authorize the Docker socket on
   VM 117.

Moving the runner onto VM 119 would isolate the GitHub runners but would let a
compromised workflow control the Forgejo server itself, so it is not equivalent
to a dedicated runner VM.

## Resumption checklist

1. Resolve the runner isolation decision above. If choosing a dedicated VM,
   update Terraform, inventory and `bootstrap/forgejo-runner/` before
   registration.
2. Create dedicated Forgejo automation credentials and store these values in
   Infisical project `homeserver`, environment `prod`, path `/Forgejo/`:

   ```text
   FORGEJO_ADMIN_USER
   FORGEJO_ADMIN_PASS
   FORGEJO_RUNNER_TOKEN
   FORGEJO_ARGO_USER
   FORGEJO_ARGO_TOKEN
   FORGEJO_REGISTRY_USER
   FORGEJO_REGISTRY_TOKEN
   ```

   Prefer a read-only repository token for Argo and a package-read token for
   registry pulls. The sync identity needs repository and organization creation
   rights during initial provisioning.
3. Fill the root-only `/etc/forgejo-sync/env` on VM 119 with
   `GITHUB_SYNC_PAT`, `FORGEJO_SYNC_USER` and `FORGEJO_SYNC_TOKEN`. Confirm the
   exact IDDH repository name and update `/etc/forgejo-sync/repos`; the initial
   suggested list is in [README.md](README.md#repository-synchronization).
4. Run one sync and only start the timer after it succeeds:

   ```bash
   ssh deployer@192.168.20.24 \
     'sudo systemctl start forgejo-sync.service && sudo systemctl start forgejo-sync.timer'
   ```

5. Register the Forgejo runner only after the isolation decision and verify a
   successful run of `.forgejo/workflows/validate.yml`.
6. After this branch is merged, sync External Secrets, Argo CD and Argo CD
   Image Updater. Re-run
   `bootstrap/k3s/argocd-image-updater-install.sh` so both registries are in the
   live updater configuration. Confirm every ExternalSecret is `SecretSynced`
   before restarting application pods.
7. Add and test `.forgejo/workflows/` in the Werify and IDDH application
   repositories. Those repositories are outside this workspace and were not
   modified. Workflows must publish the immutable/environment tags expected by
   Image Updater to the Forgejo registry. The default execution image lacks the
   Docker CLI, so image-building jobs need a tested CI image or must install the
   client.
8. Exercise staging first with a dry run, then a real cutover while GitHub is
   reachable:

   ```bash
   ./bootstrap/forgejo/switch-argo-source.sh \
     --app werify-staging --to forgejo --dry-run
   ```

   The root Argo application remains on GitHub, so the cutover commit must be
   pushed to GitHub. Repeat per application only after its Forgejo image exists
   and its staging health checks pass.

## Validation and operational follow-ups

- Persist `GH_ORGS=iddh-com-br:2,prem-prakash:12` in the GitHub runner source
  of truth. Using bare organization names reconciles both pools to the default
  of four and temporarily changes capacity.
- Test a Restic restore into a temporary directory and run SQLite integrity
  checks against the restored snapshot; the initial backup was created and
  listed, but no restore drill has been performed.
- Test the non-force sync divergence path before relying on it during an
  outage.
- Make `bootstrap/forgejo/setup.sh` distinguish an existing administrator from
  a newly created one. A rerun currently preserves the real password but can
  print a newly generated, non-effective password in its final instructions.
- The top-level Kustomize render depends on a remote Reloader base hosted on
  GitHub and could not be completed during the GitHub/network incident. All
  modified local overlays rendered successfully and must be rechecked once the
  remote base is reachable.
- Commit application workflow changes in their own repositories; this
  infrastructure PR alone does not make failover production-ready.

## Safe health checks

These commands do not change live state:

```bash
curl --fail https://forgejo.internal.prakash.com.br/api/healthz

ssh deployer@192.168.20.24 \
  'sudo systemctl is-active forgejo forgejo-db-backup.timer restic-forgejo-core.timer'

ssh deployer@192.168.20.50 \
  "systemctl list-units 'gh-runner@*.service' --state=active --no-pager"
```

Never copy token or password values into this repository, an issue, a commit
message or a pull request description.
