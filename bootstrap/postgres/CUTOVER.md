# Cutover: moving apps from PostgreSQL 17 to 18

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

`migrate-app.sh` covers rows 2, 3, 5 and 6. umami and bugsink have no
`werify`-style two-app coupling and can be done with the same steps by hand, or
by adding them to the registry in the script.

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

`iddh-members staging` and `umami` point at `192.168.20.21` rather than
`pg.internal`. The script refuses on an unexpected host rather than guessing:

```bash
OLD_HOST=192.168.20.21 ./bootstrap/postgres/migrate-app.sh iddh-members staging
```

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
