# Plane Community

Plane v1.4.2 on K3s VM 112, at https://plane.internal.prakash.com.br.
The internal wildcard DNS record already resolves to 192.168.20.11.
No VM resize is needed. PostgreSQL lives on VM 118; attachments live in
the private `plane` bucket on Garage VM 114.

## Manifests

`values.yaml` configures upstream Helm chart `plane-ce` 1.8.0. The pinned,
checksum-verified chart renders into `upstream.yaml`, which is committed so
Argo can use the repository's existing Kustomize workflow. Helm's generated
timestamps are stripped for reproducible output. Local changes live in
`kustomization.yaml` patches, not the generated file.

`ingress.yaml` declares the per-host Certificate issued by `letsencrypt-dns`
and routes web, API/auth, admin, spaces and WebSocket collaboration.

Argo applies namespace/store/secrets first, queues and configuration at wave
0, the migration Job at wave 1, and application Deployments/Ingress at wave
2. The migration Job is a Sync hook recreated on every full sync; failed
migrations prevent the application wave. Successful hooks are removed.
Use full application syncs for upgrades: selective resource sync skips hooks.

The API runs one Gunicorn worker; Celery runs two workers. PostgreSQL's
`plane` role is capped at 20 connections and connects with TLS. Each workload
has resource requests and limits. The beat scheduler uses Recreate to avoid
two periodic schedulers during a rollout. Broker ingress is limited to pods
in the `plane` namespace. Redis and RabbitMQ use 1 GiB `local-path` PVCs on
the OS disk; the PVCs are retained when StatefulSets are removed. The
StorageClass's Delete policy still applies if a PVC is explicitly deleted.

## First deployment

On the operator machine:

```sh
python3 -m venv /tmp/plane-venv
/tmp/plane-venv/bin/pip install -r scripts/plane/requirements.txt
infisical login --domain https://infisical.internal.prakash.com.br/api
/tmp/plane-venv/bin/python scripts/plane/provision.py --user
```

The operator needs Infisical folder/secret write access to `homeserver`,
environment `prod`, plus SSH/sudo on VMs 118 and 114. The ESO machine identity
only needs read access to `/Plane/`; do not widen its permissions for provisioning.
The script stores values directly in Infisical and never prints them. Existing
signing keys and passwords are retained on subsequent runs.

Provisioned keys in `/Plane/`:

- `DATABASE_URL`, `POSTGRES_PASSWORD`
- `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`
- `RABBITMQ_PASSWORD`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

ESO creates separate Secrets for app connection settings, signing keys,
collaboration, storage and RabbitMQ. Reloader restarts affected workloads
when these change. **Do not rotate `SECRET_KEY`**: it encrypts configuration
already stored in PostgreSQL. Preserve it with the database backup.

Storage sets both `AWS_S3_ENDPOINT_URL` (Plane's upload/download clients) and
`AWS_ENDPOINT_URL_S3` (botocore's fallback). The latter also directs v1.4.2's
expired-export cleanup to Garage; that task omits its explicit endpoint.

After dependency provisioning, sync the `plane` Argo application. Open
`/god-mode/` to create the first instance administrator, then create a workspace.
Self-registration is disabled. SMTP is initially unconfigured; configure a
real delivery provider in instance administration before using invitations or
password reset. Mailpit captures test messages and cannot deliver them.

## Verification and upgrades

```sh
PATH=/tmp/plane-venv/bin:$PATH bash scripts/plane/render.sh
kubectl kustomize gitops/plane > /tmp/plane.yaml
kubectl apply --dry-run=server -f /tmp/plane.yaml
kubectl -n plane get pods,externalsecrets,certificate,pvc
kubectl -n plane rollout status deployment/plane-api-wl
kubectl -n plane exec -i deployment/plane-api-wl -- python - \
  < scripts/plane/check-storage.py
curl -fsS https://plane.internal.prakash.com.br/api/instances/
```

For a new release, review chart changes, update `values.yaml` and the pinned
chart version/checksum in `scripts/plane/render.sh`, regenerate, validate,
then use a full Argo sync. Back up before schema upgrades; reverting an
image tag does not reverse database migrations.

## Data protection

The existing PostgreSQL WAL-G physical backup covers the whole PG 18 cluster,
including the new database. Garage's existing replication script enumerates
buckets readable by `replica-ro`; provisioning grants that key read access to
`plane`. The existing timer is `garage-replica.timer`. Verify a successful copy before
relying on this backup. A read grant alone does not prove replication ran.

Logs are collected by the existing Promtail DaemonSet. Existing kubelet/cAdvisor
scrapes report container usage. The installation shares the single K3s node's
availability; it does not add high availability.
