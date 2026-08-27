# PostgreSQL VM Setup

Cloud-init only preps the OS. PostgreSQL itself is installed by
`bootstrap/postgres/setup.sh`, run from your machine.

> **Migration complete — 2026-08-27.** There is now one database VM: **118**
> (`.23`, PG 18), which every command in this README assumes. VM 113 (`.21`,
> PG 17) was destroyed once all 11 connection strings had moved. The paragraphs
> below describe the two-VM period and are kept for the record.
>
> <details>
> <summary>How it read during the migration</summary>
>
> **Two VMs during the PG 18 migration.** 113 (`.21`, PG 17) is production; 118
> (`.23`, PG 18) is the blue/green target. The commands in this README assume
> **118** — running them against 113 restarts the production database.
>
> The cutover is **per application**, not global: each app's `DATABASE_URL` is
> repointed at 118 on its own schedule. The 8 databases are independent, so
> nothing forces the migration to be atomic — migrate `umami_prod` (9 MB) first,
> then a staging DB, and only then production. Blast radius is one app, and
> rollback is reverting one secret and restarting one pod while the old database
> sits untouched beside it.
>
> After migrating an app, set `ALTER DATABASE <db> CONNECTION LIMIT 0` on 113 so
> a stale config cannot silently write to the abandoned copy.
>
> </details>

## Architecture

- **OS Disk**: 20GB on SSD (local-lvm) - managed by Terraform
- **Data Disk**: 60GB on SSD (local-lvm) - managed manually in Proxmox for persistence
- **Hostname**: `pg18` on VM 118. No mDNS — reach it at
  `pg18.internal.prakash.com.br` or 192.168.20.23. (VM 113 used `pg` and
  answered to `pg.local` via Avahi; it was decommissioned 2026-08-27.)

## Data Disk Setup

The PostgreSQL data directory lives on a separate disk (`/data`) that persists independently of the VM. This allows VM recreation without data loss.

`install.sh` **aborts** if `/data` is not a mountpoint — this step is a
prerequisite, not an option.

The data disk is deliberately **not** managed by Terraform. In the `bpg/proxmox`
provider `disk` is a nested block of the VM resource, not a resource of its own,
so it cannot be protected independently: replacing the VM would take the
database with it. Keeping it outside Terraform is what makes it survive, and
`ignore_changes = [disk]` in the VM's lifecycle stops the manually-attached
scsi1 from showing up as drift.

### Create and Attach Data Disk (on Proxmox host)

```bash
# Create 60GB disk on SSD
pvesm alloc local-lvm 118 vm-118-pgdata 60G

# Attach to VM as scsi1, matching the OS disk's flags
qm set 118 --scsi1 local-lvm:vm-118-pgdata,discard=on,ssd=1,iothread=1,backup=1

# Verify
qm config 118 | grep scsi
```

`discard=on` matters here: `local-lvm` is a **thin** pool, and without TRIM
propagating from the guest the pool never reclaims deleted blocks.

### Format and Mount (on postgres VM)

```bash
# Check the device name, and confirm it is empty before formatting
lsblk
sudo blkid /dev/sdb   # must print nothing — no filesystem, no partition table

# Format (only if new/empty disk!)
sudo mkfs.ext4 -L pgdata /dev/sdb  # adjust device name as needed

# Create mount point and add to fstab. Mount by LABEL, not by device — the
# kernel is free to hand out sd* names in a different order after a reboot.
sudo mkdir -p /data
echo 'LABEL=pgdata /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
sudo systemctl daemon-reload   # otherwise systemd keeps the pre-edit fstab

# Verify — the second command is what install.sh actually checks
df -h /data
mountpoint /data
sudo findmnt --verify
```

### Putting the cluster on the data disk

**`install.sh` handles this on its own** as of 2026-08-06: if
`/data/postgresql/<ver>_main` does not exist, it runs `pg_dropcluster` +
`pg_createcluster -d` against that path. The drop is destructive, so two guards
must both hold: `/data` has to be a mountpoint, and the cluster must have no
user databases.

There is no manual step here — just run `setup.sh` with the data disk mounted.

<details>
<summary>History: the manual steps used on VM 113 (PG 17)</summary>

Before `install.sh` automated this, the relocation was done by hand, moving an
existing cluster rather than recreating it. Recorded because it explains why
113's `data_directory` is not the Debian default:

```bash
sudo systemctl stop postgresql@17-main

sudo mkdir -p /data/postgresql
sudo chown postgres:postgres /data/postgresql
sudo mv /var/lib/postgresql/17/main /data/postgresql/17_main

sudo sed -i "s|data_directory = '/var/lib/postgresql/17/main'|data_directory = '/data/postgresql/17_main'|" /etc/postgresql/17/main/postgresql.conf

sudo systemctl start postgresql@17-main
sudo -u postgres psql -l
```

For a new/empty disk the path was a direct `initdb`:

```bash
sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /data/postgresql/17_main
```

Note that this flagless `initdb` created the cluster **without** data checksums,
which was the default up to PG 17. `install.sh`'s `pg_createcluster` on PG 18
leaves them on.

</details>

## Replacing the Data Disk

If you need to swap the data disk (e.g., moving from HDD to SSD):

### 1. On postgres VM - backup and unmount

```bash
# Backup all databases first!
sudo -u postgres pg_dumpall | gzip > /tmp/pg_backup_$(date +%Y%m%d).sql.gz

# Stop PostgreSQL and unmount
sudo systemctl stop postgresql@18-main
sudo umount /data
```

### 2. On Proxmox host - swap the disk

```bash
# Detach old disk
qm set 118 --delete scsi1

# Remove old disk (adjust storage name)
pvesm free tank-vm:vm-118-pgdata  # or local-lvm:vm-118-pgdata

# Create new disk on desired storage
pvesm alloc local-lvm 118 vm-118-pgdata 60G

# Attach to VM
qm set 118 --scsi1 local-lvm:vm-118-pgdata
```

### 3. On postgres VM - format and restore

```bash
# Check device name
lsblk

# Format new disk
sudo mkfs.ext4 -L pgdata /dev/sdc

# Mount
sudo mount -a

# Recreate the cluster on the fresh disk. Prefer re-running install.sh, which
# does exactly this (pg_dropcluster + pg_createcluster -d) behind its guards:
#   POSTGRES_SSH=deployer@192.168.20.23 ./bootstrap/postgres/setup.sh
# By hand, if you must:

sudo pg_dropcluster --stop 18 main
sudo install -d -m 0755 -o postgres -g postgres /data/postgresql
sudo pg_createcluster 18 main -d /data/postgresql/18_main
sudo systemctl start postgresql@18-main

# Restore from backup
gunzip -c /tmp/pg_backup_*.sql.gz | sudo -u postgres psql
```

## Avahi/mDNS Setup

> **Correction — 2026-08-27.** This was done on VM 113 only. VM 118 does **not**
> run Avahi and is not discoverable over mDNS — `pg.local` and `pg18.local`
> both resolve to nothing. Use DNS (`pg18.internal.prakash.com.br`, managed in
> `terraform/cloudflare-dns.tf`). The steps below are kept in case a future host
> wants mDNS again.

To make the VM discoverable as `pg.local`:

```bash
sudo apt-get update && sudo apt-get install -y avahi-daemon
sudo hostnamectl set-hostname pg
sudo sed -i 's/127.0.1.1.*/127.0.1.1\tpg/' /etc/hosts
sudo systemctl enable avahi-daemon && sudo systemctl restart avahi-daemon
```

## ⚠️ Running `install.sh` drops every connection

The script ends with a cluster restart. There is no path around it for
`shared_buffers` and `reserved_connections`, both of which are *postmaster*
context. With ~122 connections held open in static Ecto pools, the restart drops
all of them at once; the pools reconnect on their own, but requests in flight
during the window fail, and a liveness probe that trips can escalate into a pod
restart. Run it deliberately, not by reflex.

## Provisioning Databases

Use `pg-provision.sh` to create databases for applications:

```bash
/opt/bootstrap/pg-provision.sh myapp              # Creates myapp_staging DB
/opt/bootstrap/pg-provision.sh myapp --env prod   # Creates myapp_prod DB
```

## Connection budget

This is a **shared instance** — every app DB (werify prod+staging, iddh prod+staging,
infisical, …) lives on the *same* PostgreSQL server and draws from one global
`max_connections` pool. Each app holds its own client-side pool (e.g. werify's
`POOL_SIZE`, plus its Go sidecar stores), so the slots add up fast.

`max_connections = 200` (set in `install.sh`; was the stock 100, which got
exhausted → clients see `FATAL 53300 too_many_connections / remaining connection
slots are reserved for roles with the SUPERUSER attribute`). Changing it requires
a restart — `install.sh` handles that, or `ALTER SYSTEM SET max_connections = N;`
then `sudo systemctl restart postgresql@18-main`. Since 2026-08-06 `install.sh`
also runs `ALTER SYSTEM RESET max_connections`, so the value comes from the
version-controlled `postgresql.conf` rather than an override that exists only on
the VM.

**Infisical has priority.** `reserved_connections = 5` (set in `install.sh`) holds
back 5 slots that only members of the predefined `pg_use_reserved_connections` role
may use once the apps have filled the rest. Infisical's role is granted that
membership in `bootstrap/infisical/db-setup.sh`, so a runaway app pool can never
lock Infisical out of its own DB (which would otherwise block *changing* the secret
that caused the runaway). Apps therefore top out at `max_connections − 3 − 5 = 192`.

> **Correction — 2026-08-06.** Until this date the paragraph above described the
> *intended* state, not the real one. An audit of the live cluster found
> `reserved_connections = 0` and `pg_auth_members` empty: the `GRANT` in
> `bootstrap/infisical/db-setup.sh:50` had never been executed. The protection
> was inert on both ends, and from ~Jan 2026 to Aug 2026 Infisical had no
> priority over the apps whatsoever. Both the value and the grant are now
> applied by `install.sh`, and take effect on its next run. Check both ends
> with:
>
> ```bash
> sudo -u postgres psql -tAc "SHOW reserved_connections;"
> sudo -u postgres psql -tAc "select r.rolname from pg_auth_members m \
>   join pg_roles r on r.oid=m.member join pg_roles g on g.oid=m.roleid \
>   where g.rolname='pg_use_reserved_connections'"
> ```

Budget when adding/scaling an app: **a rolling deploy briefly runs two pods**, so
an app can transiently need `2 × POOL_SIZE` (k8s Deployment `maxSurge`). Keep
`Σ(pool_size) × peak_pods` comfortably under `max_connections − 3` (3 slots are
reserved for superusers).

```bash
# Current usage vs cap, broken down by database
sudo -u postgres psql -c "SHOW max_connections;"
sudo -u postgres psql -c \
  "SELECT datname, usename, count(*) FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC;"
```

## Troubleshooting

```bash
# Check PostgreSQL status
sudo systemctl status postgresql@18-main

# Check logs
sudo journalctl -u postgresql@18-main -f

# Connect to database
sudo -u postgres psql

# List databases
sudo -u postgres psql -l

# Check data directory
sudo -u postgres psql -c "SHOW data_directory;"
```

## Configuration history

Configuration changes to this cluster and what motivated each one. Entries
marked **pending** are written into `install.sh` but do not yet hold on the live
cluster — they take effect on the script's next run.

| Date | Change | Reason | Status |
|---|---|---|---|
| 2026-08-06 | `shared_buffers` 128MB → 2GB | 7.7 GB VM running the 128MB default; the ~925 MB of data now fits entirely | pending |
| 2026-08-06 | `random_page_cost` 4 → 1.1 | The default assumes spinning rust and makes the planner underestimate index scans on SSD | pending |
| 2026-08-06 | `effective_cache_size` 4GB → 5GB | Reflect the RAM actually available for cache | pending |
| 2026-08-06 | `maintenance_work_mem` 64MB → 256MB | VACUUM and index builds; few run concurrently | pending |
| 2026-08-06 | `reserved_connections` 0 → 5 | Documented as active since ~Jan 2026, but the value was 0 and the `GRANT` never ran — see the correction note above | pending |
| 2026-08-06 | `max_connections` moves from `postgresql.auto.conf` to `postgresql.conf` | The value existed only on the VM, outside git, from a manual `ALTER SYSTEM` | pending |
| 2026-08-06 | certbot/Let's Encrypt dropped from the Postgres path | The cluster is LAN-only and served the snakeoil cert despite all the DNS-01 machinery — the `sed` looked for a commented line that Debian ships uncommented | pending |
| ~2026-01 | `max_connections` 100 → 200 | Pool exhausted in production: `FATAL 53300 too_many_connections` | applied (via `ALTER SYSTEM`, outside git) |
| ~2025-11 | `data_directory` moved to `/data/postgresql/17_main` | Separate data disk, so the database survives VM recreation | applied |

