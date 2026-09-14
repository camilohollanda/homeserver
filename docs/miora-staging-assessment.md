# Miora staging: migrations and persistence

Assessment on 2026-09-13, using Miora commit `7533c12`, the deployed manifests,
PostgreSQL, Garage, and the current Infisical configuration. This assessment
does not change the application's migration procedure or allocate storage.

## Migrations

The image already contains `bin/migrate`, which evaluates
`Miora.Release.migrate/0`. That function loads the application's Ecto repos and
runs pending migrations through `Ecto.Migrator.with_repo/2`. `bin/server` invokes
the migration script before starting Phoenix, so each pod startup runs the
migration check. The Deployment currently relies on this entrypoint.

A separate Argo CD PreSync Job is feasible using the Werify pattern:

- Run `/app/bin/migrate` with the same image name and tag as the Deployment;
  Kustomize's Image Updater override must pin both to the same digest.
- Reuse `ghcr-credentials` and `secrets` in `miora-staging`.
- Give the Job its own label so neither HTTP nor discovery Services select it.
- Use `BeforeHookCreation`, a deadline and no automatic retries, retaining the
  previous result until the next full sync.
- Change the Deployment command to `/app/bin/miora start` with
  `PHX_SERVER=true`, otherwise startup still invokes the second migration path.
- Keep namespace and both Secrets present before a first PreSync execution.
  Selective syncs do not execute the hook; deploy and rollback procedures must
  use a full sync and database-compatible application versions.

Recommendation: adopt the PreSync Job in a separate change. It will prevent an
image rollout when migrations fail and make the migration result visible in
Argo CD. The current startup procedure does already run migrations; there is
no missing executable to implement first. `POOL_SIZE=5` is appropriate to keep
in the app manifest while sizing any extra migration connection use against
the shared PostgreSQL budget.

## Persistence

The durable stores are already external to the application pod:

- **PostgreSQL 18, VM 118:** database and role `miora_staging`, including Ecto
  records and Oban jobs. The instance has WAL archiving enabled and a scheduled
  WAL-G base backup. The 2026-09-13 base backup completed successfully; this is
  backup execution evidence, not a restore test.
- **Garage:** bucket `miora-staging` for media objects. The runtime adapter is
  `Miora.Media.Storage.S3`, backed by ReqS3. The local filesystem adapter is for
  tests and offline development.

The current `MEDIA_S3_ENDPOINT` is `https://storage-staging.miora.now`, replacing
the earlier `garage-ui.internal.prakash.com.br` value observed during the first
inventory. The app's database URL still uses `192.168.20.23`; standardizing it
on `pg18.internal.prakash.com.br` is an independent configuration change.

Recommendation: **do not copy Werify's 100 GiB PVC or its `/app/priv` mount.**
Miora's durable media already belongs in S3. Mounting a new volume over release
assets adds a separate storage lifecycle without serving the current design.
If later processing needs significant temporary disk, size ephemeral storage
or an `emptyDir` for that workload rather than treating it as durable media.

Before treating persistence as recoverable, validate the bucket credentials,
region, upload/download paths and a restore of both the database and media.
The services VM's `restic-garage-meta` job backs up Garage metadata; that job
alone does not prove the media object payloads have an independent backup.
Keep the database records and S3 objects consistent when designing recovery.

## Scope of the observability change

The Miora dashboard deliberately has no local PVC or connector panels. It uses
the existing resource scrapes and ingress logs. Logs need a Miora-specific text
pipeline, while notifications need an environment-specific Pushover token and
Bugsink needs both a project DSN and an instrumented application image.

See [the deployment runbook](../gitops/staging/miora/README.md#observability)
for the activation order and required secret names.
