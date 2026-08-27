# Cutover: moving apps from PostgreSQL 17 to 18

> **Done — 2026-08-27.** Every app is on VM 118, VM 113 has been destroyed, and
> `migrate-app.sh` has been deleted along with it — it needed a live source
> cluster on `.21`, so every run would have failed at the preflight. Recover it
> from git if it is ever wanted again:
> `git show 3b3052d:bootstrap/postgres/migrate-app.sh`.
>
> **Two items are still open**, both in the checklist at the end of this file:
> the `pg.internal` repoint is written but not applied, and the `DATABASE_URL`s
> have not been normalised off `pg18` yet. Everything else here is the record of
> how the migration was carried out — the command blocks below invoke a script
> that no longer exists.

The 8 databases are independent — nothing in Postgres queries across them — so
the migration is **per application**, not one switch. Each app moves on its own
schedule, its own blast radius is one app, and the database it leaves behind
stays complete and untouched.

A single DNS repoint of `pg.internal` was considered and rejected: six of the
nine live connection strings resolve through that name, so moving it would
migrate everything at once and make rollback wait on TTL expiry.

## Order

Increasing stakes. Do not start at the top of the list.

| # | App | Environment | Database | Why here |
|---|---|---|---|---|
| 1 | umami | prod | `umami_prod` | 9 MB, analytics only — nobody notices |
| 2 | iddh-members | staging | `iddh_members_staging` | first real app, no users |
| 3 | werify | staging | `werify_staging` | first two-deployment app, no users |
| 4 | bugsink | prod | `bugsink` | error sink; losing minutes costs nothing |
| 5 | iddh-members | production | `iddh_members_prod` | first real users |
| 6 | werify | production | `werify` | largest, and the connector rides with it |
| 7 | infisical | — | `infisical` | **last, and by hand** — see below |

`migrate-app.sh` covered every row except infisical.

### Infisical is last, and is not scriptable

Infisical is the vault every other `DATABASE_URL` lives in, and **its own**
connection string lives in `/opt/infisical/.env` on VM 114 — not inside
Infisical. Migrating it before the others would risk locking you out of the
secrets needed to migrate the others. Move it only once everything else is on
VM 118, by editing that file and restarting the container.

## Per-app cutover

```bash
# always start here — touches nothing
./bootstrap/postgres/migrate-app.sh werify staging --dry-run

# then, for real
./bootstrap/postgres/migrate-app.sh werify staging
```

What it does, in order:

1. **Preflight** — reads `DATABASE_URL` from Infisical, verifies every other
   connection key for that app agrees on the same host and database, checks the
   source is reachable *from VM 118*, and refuses if the target already holds
   tables.
2. **Quiesce** — pauses ArgoCD reconcile, scales the deployments to zero, and
   waits until the pods are *gone*, not merely terminating.
3. **Dump and restore** — both run on VM 118, so the client versions match the
   servers and the dump never crosses your laptop.
4. **Verify** — compares per-table row counts between source and copy. A
   mismatch aborts **before** any secret changes, leaving the app down but the
   old database current.
5. **Switch** — rewrites the secrets in Infisical, then waits for External
   Secrets to land the new value in the k8s Secret before scaling up. A pod that
   starts too early would boot against the old host.
6. **Restore service** — scales up, resumes ArgoCD.
7. **Lock the old copy** — `ALTER DATABASE ... CONNECTION LIMIT 0` on VM 113, so
   a stale config cannot quietly write to a database nobody reads any more. The
   data stays; only new connections are refused.

### Rollback

```bash
./bootstrap/postgres/migrate-app.sh werify staging --rollback
```

Cheap because the old database was never dropped. Note that anything written to
VM 118 after the cutover does **not** come back — roll back promptly or accept
the loss.

If a run aborts midway, it says so and leaves the app scaled down on purpose:

```bash
./bootstrap/postgres/migrate-app.sh werify staging --resume-only
```

### Apps whose URL carries a raw IP

`umami` points at `192.168.20.21` rather than `pg.internal`. The script refuses
on an unexpected host rather than guessing:

```bash
OLD_HOST=192.168.20.21 ./bootstrap/postgres/migrate-app.sh umami prod
```

### bugsink shares its namespace

`apprise-shim` runs alongside `bugsink` and is deliberately **not** scaled down:
its entire environment is `APPRISE_KEY` / `APPRISE_URL` / `TAG_FALLBACK`, so it
holds no Postgres connection and stopping it would be downtime for nothing.

## Why the quiescing is not just `kubectl scale`

Three failure modes, all measured on this cluster and all inherited from
werify's `scripts/clone_prod_to_staging.sh`, which paid for them first:

**ArgoCD self-heals into the gap.** `skip-reconcile` and `scale --replicas=0`
are not atomic; a sync queued before the annotation was observed can put
replicas back to 1 seconds later. `werify-connector` is the exposed one — its
manifest pins `replicas: 1` because the whatsmeow session is a singleton, so
scaling it to zero is real drift that ArgoCD fights. The script re-asserts the
scale-down on every poll.

**`.status.replicas` lies.** It counts *active* pods, so it goes absent within
about six seconds while the pod stays `Running` — still holding its Postgrex
pool — for the remainder of its grace period. Grace is 45s for `werify` and
`iddh-members`, 30s for `werify-connector`. The script counts actual pod objects
instead.

**A failed `kubectl` read is not zero pods.** Collapsing "no answer" into "none"
is how you end up dumping a live database. Reads that fail are retried; only a
confirmed zero proceeds.

## werify is two apps

`werify` and `werify-connector` share **one database** and are separate
deployments under separate ArgoCD applications. Both hold connections, so both
must be down before the dump, and both come back after.

Their credentials are two separate secrets — `DATABASE_URL` and
`SIDECAR_DATABASE_URL` — pointing at the same database. The script verifies they
agree before starting and rewrites both together. Moving only one would leave
the connector writing to VM 113 while the web app writes to VM 118: two writers
on two diverging copies, the worst outcome available.

## The lock does not stop superusers

`ALTER DATABASE ... CONNECTION LIMIT 0` blocks the app's role. It does **not**
block superusers, and it does not drop connections that already exist — it only
refuses new ones.

So an open GUI client (TablePlus, DBeaver, pgAdmin) connected as `postgres`
keeps working against the abandoned copy after the cutover, with no error to
suggest anything changed. A `SELECT` there returns data frozen at the moment of
the migration; an `UPDATE` writes to a database nobody reads and that disappears
when VM 113 is decommissioned.

Found in practice: a TablePlus session idle for nine days survived the lock on
`iddh_members_prod` because it was connected as `postgres`.

After migrating an app, repoint any saved connections at
`pg18.internal.prakash.com.br`. To find them:

```sql
-- on VM 113, anything still attached to a migrated database
SELECT datname, usename, application_name, client_addr,
       now() - backend_start AS age, state
  FROM pg_stat_activity
 WHERE datname IN (SELECT datname FROM pg_database WHERE datconnlimit = 0);
```

## After each app

- Watch it come up: `kubectl logs -n <ns> deployment/<app> -f`
- Remove the dump from VM 118 — it is customer data in the clear. The script
  prints the path.
- The old database stays on VM 113, locked. Keep it until you are confident.

## When every app has moved

1. Confirm nothing connects to VM 113:
   `sudo -u postgres psql -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY 1"`
2. Take a final wal-g backup of VM 113 and let its retention age out naturally.
3. Repoint `pg.internal.prakash.com.br` at `192.168.20.23` in
   `terraform/cloudflare-dns.tf`, and drop the `pg18` record.
4. Normalise the `DATABASE_URL`s onto `pg.internal` — one sweep, at leisure,
   with no version in the name.
5. Set `prevent_destroy = true` on VM 118 in `terraform/vm-postgres-18.tf`.
6. Only then destroy VM 113, freeing 80 GB on the `local-lvm` thin pool.

### Status of that checklist — 2026-08-27

Note that steps 3 and 6 ran out of order: VM 113 was destroyed before the DNS
repoint landed, which left `pg.internal` resolving to a dead address for as long
as the gap lasted. Nothing depended on it — all 11 connection strings name
`pg18` — so the exposure was nil, but the ordering above is the safe one.

| # | Step | Status |
|---|------|--------|
| 1 | Confirm nothing connects to 113 | Done — all 10 k8s secret keys and Infisical's own `DATABASE_URL` name `pg18` |
| 2 | Final wal-g backup of 113 | Assumed done before the destroy; the `wal-g` prefix is frozen and ages out on its own |
| 3 | Repoint `pg.internal` at `.23`; drop `pg18` | **Repoint written to `cloudflare-dns.tf`, not yet applied.** `pg18` deliberately NOT dropped — see step 4 |
| 4 | Normalise `DATABASE_URL`s onto `pg.internal` | **Not started.** Must happen before `pg18` can be dropped, or every app loses its database at once |
| 5 | `prevent_destroy = true` on VM 118 | Done — already set in `terraform/vm-postgres-18.tf` |
| 6 | Destroy VM 113 | Done — gone from Proxmox and dropped from Terraform state on refresh |
