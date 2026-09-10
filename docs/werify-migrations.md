# Werify deployment migrations

Werify migrations run in `Job/werify-migrate` before Argo CD rolls out the
application in `werify-staging` or `werify-production`. Each full sync starts a
`PreSync` hook with `/app/bin/migrate`; the Deployment runs
`/app/bin/werify start` with `PHX_SERVER=true` only. This also bypasses migrations
in older images whose `bin/server` still calls the migrator.

A failed migration, image pull, missing Secret, or 30-minute deadline prevents
Argo CD from entering the Sync phase. Existing application pods keep serving,
but the database may already contain changes made by the hook. `PreSync` is an
ordering gate, not a transaction around the release.

## Image and runtime contract

Both workloads reference `ghcr.io/prem-prakash/werify` with `:staging` or `:main`.
The existing Image Updater tracks the environment tag by digest and writes the
Application's `spec.source.kustomize.images` override. Kustomize transforms the
Job and Deployment together; no second image alias or promotion is needed.
Confirm the rendered workloads use the same `@sha256:` image before deploying.
Mutable tags alone cannot guarantee the same image across the two phases.
Image Updater's `argocd` write-back lives in the Application, so recreating that
Application requires restoring/waiting for its digest override before sync.
See [Image Updater write-back](https://argocd-image-updater.readthedocs.io/en/stable/basics/update-methods/).

The Job uses the same `secrets` envFrom and `ghcr-credentials` image pull Secret
as the app. `Werify.Release.migrate` loads the release and repositories without
starting the application's supervisor or HTTP endpoint. Migrations are packaged
under the release's application directory; the `/app/priv` upload PVC is not
needed. The Job has no HTTP probes or Service ports, and `app: werify-migrate`
keeps it out of both the HTTP and headless Service selectors.

The Job requests 256 MiB / 100m CPU and is capped at 1 GiB / 1 CPU. It has one
completion, parallelism one, `restartPolicy: Never`, and `backoffLimit: 0`.
These settings avoid normal pod restart/retry loops, but Kubernetes Jobs do not
promise exactly-once execution. A later full sync runs a new Job. Ecto's
`schema_migrations` records completed migrations; migrations and nontransactional
recovery still need to tolerate interruption and reruns. Do not run independent
migration Jobs or release commands against the same database during a sync.

## Prerequisites and adoption

Merge and sync this homeserver change **before** deploying the Werify change
that removes migrations from `bin/server`. The command override works with
current images, allowing the infrastructure gate to be adopted first. Avoid
promoting another app image during that first sync, and verify the hook and
rollout in both environments before deploying the application change.

`PreSync` runs before ordinary resources, including this application's
ExternalSecrets. The namespace, External Secrets Operator, ClusterSecretStores,
and generated `secrets` / `ghcr-credentials` Secrets must already exist and be
ready. Both current environments are already provisioned. `CreateNamespace=true`
is not a bootstrap mechanism for the generated Secrets.

For a new or restored environment, provision the namespace and the two
ExternalSecret manifests as a separate bootstrap step before enabling the
Application's full sync. Wait for ESO to reconcile both Secrets. Likewise,
changes that rename or replace a Secret/SecretStore needed by the hook must be
staged before the migration-bearing release; the hook cannot rely on an
ExternalSecret update in the same sync. Normal Infisical value refreshes continue
through ESO. Check readiness without printing secret values:

```bash
WERIFY_ENV=staging # or production
kubectl -n "werify-$WERIFY_ENV" get externalsecret werify-secrets ghcr-credentials
kubectl -n "werify-$WERIFY_ENV" get secret secrets ghcr-credentials
kubectl -n argocd get application "werify-$WERIFY_ENV" \
  -o jsonpath='{.spec.source.kustomize.images}{"\n"}'
argocd app manifests "werify-$WERIFY_ENV" | \
  yq 'select(.kind == "Job" or .kind == "Deployment") | .spec.template.spec.containers[].image'
```

Keep production's existing `startupProbe.failureThreshold: 900` at two seconds
per check during adoption. It is no longer the migration timeout; the Job owns
its 1800-second deadline. Reduce the startup allowance separately once normal
application boot time has been measured.

## Inspect a failure and retry

The named Job and its pods remain after success or failure. Only
`BeforeHookCreation` is set, so the next full sync deletes the previous Job
before creating its replacement. Capture logs/events before retrying:

```bash
WERIFY_ENV=staging # or production
kubectl -n "werify-$WERIFY_ENV" get job werify-migrate
kubectl -n "werify-$WERIFY_ENV" get pods -l job-name=werify-migrate
kubectl -n "werify-$WERIFY_ENV" describe job werify-migrate
kubectl -n "werify-$WERIFY_ENV" describe pods -l job-name=werify-migrate
kubectl -n "werify-$WERIFY_ENV" logs job/werify-migrate --all-containers=true
argocd app get "werify-$WERIFY_ENV"
```

Fix the cause before retrying: inspect database locks, partially completed
nontransactional work (including invalid concurrent indexes), Secret readiness,
image availability, or resource/deadline exhaustion as applicable. Bulk backfills
belong in a separate resumable operation, not in a longer deploy hook. Confirm
no other migration runner is still active. Do not assume automated sync will
retry a failed revision without an explicit retry or a new change.

Once corrected, perform a **full application sync** and wait for its result:

```bash
argocd app sync "werify-$WERIFY_ENV"
argocd app wait "werify-$WERIFY_ENV" --operation --sync --health --timeout 2100
```

Never use resource-selective sync (including `--resource`),
`ApplyOutOfSyncOnly=true`, or `kubectl set image` to deploy Werify: selective sync
skips hooks, and direct Deployment changes bypass Argo CD's gate. Reloader and
pod restarts continue to restart the already selected release without migrating.
Hook semantics are documented in [Argo CD sync phases and waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

## Compatibility and rollback

The previous version stays live while migrations run. Use changes compatible
with both old and new code: expand first, deploy compatible readers/writers,
backfill separately, then contract only once old code is retired. The gate does
not make long locks, destructive changes, or bulk updates safe.

Rollback by promoting the previously built application digest through the
normal environment tag/Image Updater path and full sync. Keep the Deployment's
direct release command. This rolls back **code**, not the database; it does not
run down migrations. Check schema compatibility before selecting an older
release. Repair schema problems with a reviewed forward migration or a separate
recovery procedure.

## Local verification

Run from the repository root with Python 3, kubectl (with Kustomize), and
[Mike Farah yq v4](https://github.com/mikefarah/yq) installed:

```bash
python3 scripts/check-werify-migrations.py
```

The check renders both environments and two simulated image-updater digests,
then asserts migration ordering, failure/retention settings, image/Secret parity,
Service isolation, direct HTTP startup, and full-sync Application configuration.
It never contacts a cluster. Server-side dry-run can additionally validate the
rendered Jobs and Deployments against the target Kubernetes API without saving
them. Neither check exercises a real migration or proves the live Argo CD
failure path; verify that during an explicitly scheduled staging rollout.
