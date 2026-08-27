# Restoring PostgreSQL from wal-g

Proven working on 2026-08-06: the VM 113 production backup was restored onto a
scratch cluster and row counts matched production exactly (`werify.users` 10,
`werify.conversations` 58, all 8 databases at their expected sizes).

## What the backup does and does not contain

wal-g backs up the **data directory**. On Debian the configuration lives in
`/etc/postgresql/<ver>/main/`, outside it, so `postgresql.conf`, `pg_hba.conf`
and `pg_ident.conf` are **not** in the backup.

That is deliberate, not a gap. Configuration is reproducible from git —
`bootstrap/postgres/install.sh` generates all of it — so the split is: **config
from the repository, data from the backup.** Putting config inside the backup
would create a second source of truth that drifts from the repo.

The one thing recovery genuinely needs from the source cluster is already
carried inside the backup, in `pg_control`. See step 3.

## Procedure

### 1. Stand up a cluster with the right config

```bash
POSTGRES_SSH=deployer@<new-vm> ./bootstrap/postgres/setup.sh
```

This installs PostgreSQL, creates the cluster on `/data`, and writes the tuned
`postgresql.conf` and `pg_hba.conf`. The data it creates is thrown away in the
next step — what matters is the configuration.

### 2. Stop it and fetch the backup over the data directory

```bash
sudo systemctl stop postgresql@18-main
sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; set +a; wal-g backup-list'
sudo rm -rf /data/postgresql/18_main
sudo install -d -m 0700 -o postgres -g postgres /data/postgresql/18_main
sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; set +a; \
  wal-g backup-fetch /data/postgresql/18_main LATEST'
```

Use `LATEST` or a specific `base_...` name from `backup-list`.

### 3. Match the parameters the source cluster used

Recovery **refuses to start** if the recovering cluster allows fewer connections,
workers, locks or prepared transactions than the cluster the backup came from.
The required values are recorded in the backup itself — read them, do not guess:

```bash
sudo /usr/lib/postgresql/18/bin/pg_controldata /data/postgresql/18_main \
  | grep -E 'max_|Data page checksum'
```

```
max_connections setting:              200
max_worker_processes setting:         8
max_wal_senders setting:              10
max_prepared_xacts setting:           0
max_locks_per_xact setting:           64
```

Every `max_*` in `postgresql.conf` must be **greater than or equal to** what is
printed. `install.sh` already sets `max_connections = 200`, which covers the
current cluster; check anyway, because the error only surfaces after the fetch.

### 4. Point recovery at the archive and start

```bash
sudo tee /usr/local/bin/wal-g-fetch >/dev/null <<'EOF'
#!/bin/sh
set -a; . /etc/wal-g/wal-g.env; set +a
exec /usr/local/bin/wal-g wal-fetch "$1" "$2"
EOF
sudo chmod 0755 /usr/local/bin/wal-g-fetch

sudo -u postgres tee -a /etc/postgresql/18/main/postgresql.conf >/dev/null <<'EOF'
restore_command = '/usr/local/bin/wal-g-fetch %f %p'
EOF

sudo -u postgres touch /data/postgresql/18_main/recovery.signal
sudo systemctl start postgresql@18-main
```

For point-in-time rather than latest, add `recovery_target_time = '...'` before
starting.

Watch it reach consistency:

```bash
sudo tail -f /var/log/postgresql/postgresql-18-main.log
# LOG:  restored log file "..." from archive
# LOG:  consistent recovery state reached at ...
# LOG:  database system is ready to accept read-only connections
```

### 5. Promote

The cluster comes up **read-only**. Once the data looks right:

```bash
sudo -u postgres psql -c "SELECT pg_promote()"
sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()"   # must print f
```

## Restoring onto a scratch cluster instead

To verify a backup without touching a live cluster, fetch into a separate
directory and start it on another port with `pg_ctl` directly. Two things the
data directory will not have, because Debian keeps them in `/etc`:

- **`pg_hba.conf` and `pg_ident.conf`** — the server refuses to start without
  them. `local all all trust` is enough for a scratch check.
- **`postgresql.conf`** — needs at minimum `port`, the `max_*` values from
  step 3, and `restore_command`.

Always set **`archive_mode = off`** on a scratch cluster. Without it, a promoted
restore starts pushing WAL into the same prefix as the cluster it was restored
from, which corrupts that prefix's timeline.

## Restoring a PostgreSQL 17 backup

wal-g backups are **physical**, so they are locked to the major version that
wrote them. A PG 17 data directory cannot be started by PG 18 binaries. To read
VM 113's backups, install `postgresql-17` alongside and use
`/usr/lib/postgresql/17/bin/`; Debian keeps versions side by side without
conflict. Those binaries are already installed on VM 118 for this reason.

Migrating data across major versions is a job for `pg_dumpall`, not for a
physical restore.

## Prefixes

| Prefix | Cluster |
|---|---|
| `s3://homeserver-pg-walg/wal-g` | VM 113, PostgreSQL 17 (host decommissioned 2026-08-27; the prefix still holds its final backups until retention ages them out — nothing writes to it any more) |
| `s3://homeserver-pg-walg/wal-g-18` | VM 118, PostgreSQL 18 |

Both are encrypted with the same `WALG_LIBSODIUM_KEY` (stored in Infisical under
`/backups/wal-g/`). **Losing that key loses both.** A new cluster must never
reuse an existing prefix — it restarts WAL numbering at
`000000010000000000000001` and collides with the old cluster's segment names.
