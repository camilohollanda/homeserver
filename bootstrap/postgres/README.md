# PostgreSQL VM Setup

PostgreSQL is installed automatically via cloud-init when the VM is created. The VM is accessible at `pg.local` via mDNS (Avahi).

## Architecture

- **OS Disk**: 20GB on SSD (local-lvm) - managed by Terraform
- **Data Disk**: 60GB on SSD (local-lvm) - managed manually in Proxmox for persistence
- **Hostname**: `pg` (accessible as `pg.local`)

## Data Disk Setup

The PostgreSQL data directory lives on a separate disk (`/data`) that persists independently of the VM. This allows VM recreation without data loss.

### Create and Attach Data Disk (on Proxmox host)

```bash
# Create 60GB disk on SSD
pvesm alloc local-lvm 113 vm-113-pgdata 60G

# Attach to VM as scsi1
qm set 113 --scsi1 local-lvm:vm-113-pgdata

# Verify
qm config 113 | grep scsi
```

### Format and Mount (on postgres VM)

```bash
# Check disk device name
lsblk

# Format (only if new/empty disk!)
sudo mkfs.ext4 -L pgdata /dev/sdc  # adjust device name as needed

# Create mount point and add to fstab
sudo mkdir -p /data
echo 'LABEL=pgdata /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a

# Verify
df -h /data
```

### Migrate PostgreSQL Data to /data

```bash
# Stop PostgreSQL
sudo systemctl stop postgresql@17-main

# Create directory and move data
sudo mkdir -p /data/postgresql
sudo chown postgres:postgres /data/postgresql
sudo mv /var/lib/postgresql/17/main /data/postgresql/17_main

# Update config to use new location
sudo sed -i "s|data_directory = '/var/lib/postgresql/17/main'|data_directory = '/data/postgresql/17_main'|" /etc/postgresql/17/main/postgresql.conf

# Start PostgreSQL
sudo systemctl start postgresql@17-main

# Verify
sudo -u postgres psql -l
```

### Initialize Fresh (if new disk)

If the data disk is new/empty:

```bash
sudo mkdir -p /data/postgresql
sudo chown postgres:postgres /data/postgresql
sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /data/postgresql/17_main
sudo systemctl start postgresql@17-main
```

## Replacing the Data Disk

If you need to swap the data disk (e.g., moving from HDD to SSD):

### 1. On postgres VM - backup and unmount

```bash
# Backup all databases first!
sudo -u postgres pg_dumpall | gzip > /tmp/pg_backup_$(date +%Y%m%d).sql.gz

# Stop PostgreSQL and unmount
sudo systemctl stop postgresql@17-main
sudo umount /data
```

### 2. On Proxmox host - swap the disk

```bash
# Detach old disk
qm set 113 --delete scsi1

# Remove old disk (adjust storage name)
pvesm free tank-vm:vm-113-pgdata  # or local-lvm:vm-113-pgdata

# Create new disk on desired storage
pvesm alloc local-lvm 113 vm-113-pgdata 60G

# Attach to VM
qm set 113 --scsi1 local-lvm:vm-113-pgdata
```

### 3. On postgres VM - format and restore

```bash
# Check device name
lsblk

# Format new disk
sudo mkfs.ext4 -L pgdata /dev/sdc

# Mount
sudo mount -a

# Initialize PostgreSQL
sudo mkdir -p /data/postgresql
sudo chown postgres:postgres /data/postgresql
sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /data/postgresql/17_main

# Start PostgreSQL
sudo systemctl start postgresql@17-main

# Restore from backup
gunzip -c /tmp/pg_backup_*.sql.gz | sudo -u postgres psql
```

## Avahi/mDNS Setup

To make the VM discoverable as `pg.local`:

```bash
sudo apt-get update && sudo apt-get install -y avahi-daemon
sudo hostnamectl set-hostname pg
sudo sed -i 's/127.0.1.1.*/127.0.1.1\tpg/' /etc/hosts
sudo systemctl enable avahi-daemon && sudo systemctl restart avahi-daemon
```

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
then `sudo systemctl restart postgresql@17-main`.

**Infisical has priority.** `reserved_connections = 5` (set in `install.sh`) holds
back 5 slots that only members of the predefined `pg_use_reserved_connections` role
may use once the apps have filled the rest. Infisical's role is granted that
membership in `bootstrap/infisical/db-setup.sh`, so a runaway app pool can never
lock Infisical out of its own DB (which would otherwise block *changing* the secret
that caused the runaway). Apps therefore top out at `max_connections − 3 − 5 = 192`.

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
sudo systemctl status postgresql@17-main

# Check logs
sudo journalctl -u postgresql@17-main -f

# Connect to database
sudo -u postgres psql

# List databases
sudo -u postgres psql -l

# Check data directory
sudo -u postgres psql -c "SHOW data_directory;"
```
