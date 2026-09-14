# Miora staging

- Source: [Cawser/miora](https://github.com/Cawser/miora).
- Host: `https://staging.miora.now`, through the homeserver Cloudflare Tunnel.
- Argo CD application and namespace: `miora-staging`.
- Image: `ghcr.io/cawser/miora:staging`, followed by digest by Image Updater.
- Secrets: Infisical project `homeserver` (`homeserver-1jj1`), environment
  `staging`, path `/Miora/`.

Only staging is configured. TLS terminates at Cloudflare; the Ingress forwards
HTTP to Phoenix on port 4000. Miora staging is intentionally public, without a
Cloudflare Access gate, until its production environment launches. The app's
own authentication still applies. Werify and IDDH staging keep their existing
WARP/IP/identity policies.

## First deployment prerequisites

1. **Publish a release image.** The app repository builds a `linux/amd64`
   Phoenix release with production assets and publishes
   `ghcr.io/cawser/miora:staging`. At commit `7533c12`, `bin/server` runs
   `bin/migrate` before starting Phoenix. These manifests use that image
   entrypoint; there is no separate migration Job yet. The shared
   `GHCR_USERNAME`/`GHCR_TOKEN` must have read access to
   that package, including Image Updater's registry credentials.

2. **Create the database on VM 118.** Use the existing provisioner once for the
   new `miora_staging` database and role:

   ```sh
   REMOTE_HOST=deployer@192.168.20.23 \
     ./bootstrap/postgres/pg-provision.sh miora --env staging
   ```

   The provisioner prints credentials and rotates the role's password if it
   already exists. Store `DATABASE_URL` in Infisical at the path above, using
   `pg18.internal.prakash.com.br:5432` as the database host. Add a
   `SECRET_KEY_BASE` generated with `mix phx.gen.secret`. Keep these values out
   of git. The Deployment sets `PHX_SERVER=true`, `PHX_HOST=staging.miora.now`,
   `PORT=4000`, and `POOL_SIZE=5`; a rolling deployment briefly needs two pools.

3. **Configure Cloudflare.** Add `miora_now` to `cloudflare_zone_ids` in the
   local Terraform configuration with the zone ID for `miora.now`. If using
   `TF_VAR_cloudflare_zone_ids`, update that value too. The provider token needs
   access to this zone. The proxied CNAME `*.miora.now` points subdomains at
   the tunnel; it does not cover the apex `miora.now`. Only `staging.miora.now`
   has a tunnel route and Ingress. Other subdomains reaching the tunnel fall
   through to its HTTP 404 rule until their routes are added. Review a
   Terraform plan for the DNS record and tunnel route before applying.
   Do not apply unrelated VM changes as part of adding this hostname.

4. **Sync and verify.** Once the image, database and secrets exist, commit/push
   the GitOps changes so the root Argo CD application discovers `miora-staging`.
   Check ExternalSecret synchronization and Deployment readiness, then verify
   HTTPS and a LiveView connection from a public client without WARP or an
   Access session.

The current app has no `/health` route, so probes request `/` with
`X-Forwarded-Proto: https` to satisfy Phoenix `force_ssl`. This checks HTTP
serving, not database readiness. Switch to a dedicated health endpoint when the
application provides one. The app must also configure a mail adapter before
testing email login/confirmation; for staging, use the existing Mailpit service
with STARTTLS and authentication.

## Observability

The dedicated [Miora staging dashboard](../../grafana/dashboards/miora-staging.json)
uses the shared Loki and VictoriaMetrics datasources. Its 12 panels cover HTTP
requests from ingress access logs, memory, CPU, observed container restarts,
network traffic, log volume by level, and application logs. It has no local-disk
or WhatsApp connector panels because Miora has neither resource.

[Promtail](../../loki-stack/promtail.yaml) parses Miora's text Logger output,
groups multiline stack traces and extracts the severity label. It preserves
the CRI timestamp, which includes the date. Existing logs are not relabeled;
severity filtering applies to newly collected events after the parser reloads.

The notification routes are `miora-staging` (Argo CD, pod restarts and Bugsink),
`oom-miora-staging`, and `reload-miora-staging`. Before syncing the Apprise
ExternalSecret, create the Pushover application **Miora - Staging** and store
`PUSHOVER_TOKEN_MIORA_STAGING` in Infisical `prod` → `/Shared/`. This is a
required key in the shared Apprise template; do not deploy the reference before
the key exists. No support-message route is configured for Miora.

Bugsink uses project `miora-staging` and a Slack-format webhook to
`http://apprise-shim.bugsink.svc.cluster.local/hook/miora-staging`.
Its DSN belongs in Infisical `staging` → `/Miora/` → `SENTRY_DSN`.
The application image must include the Sentry SDK integration and use
`ENVIRONMENT=staging`; setting the DSN alone does not instrument an old image.

Deployment verification:

1. Confirm the Pushover key and DSN exist without printing their values.
2. Sync Grafana, Loki and Apprise through Argo CD. Confirm their ExternalSecrets
   report `SecretSynced` and the workloads are healthy.
3. Reload Promtail's config and restart Apprise after its rendered Secret
   changes. The Reloader controller was scaled to zero during the 2026-09-13
   audit, so annotations alone do not currently perform these reloads.
4. Deploy the Miora image with the SDK and check the effective environment and
   Logger handler. Use a synthetic error to verify ingestion before enabling
   Bugsink's project alerts and verify Apprise recognizes the new tags.
5. Open `/d/miora-staging` in Grafana, check HTTP and resource panels, and confirm
   new Miora log streams carry `level`. The shared pod and database dashboards
   remain available as before.

See the [migration and persistence assessment](../../../docs/miora-staging-assessment.md)
before adding a migration Job or a local volume.

## When production launches

Restore the staging restriction by adding Miora to `staging_gated_hosts` in
`terraform/cloudflare-access.tf`:

```hcl
miora_staging = {
  domain       = "staging.miora.now"
  webhook_path = null
  public_paths = []
}
```

Review and apply the Terraform plan to attach the existing staging
WARP/IP/identity policies. Confirm that public clients encounter the Access
gate and authorized clients can still reach the application.

## Validation

```sh
kubectl kustomize gitops/staging/miora
kubectl kustomize gitops
terraform -chdir=terraform fmt -check cloudflare-access.tf cloudflare-dns.tf cloudflare-tunnel.tf variables.tf
terraform -chdir=terraform validate
```

Local validation does not publish an image, provision the database, create
Infisical secrets or apply the Cloudflare configuration.
