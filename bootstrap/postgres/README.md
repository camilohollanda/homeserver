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
