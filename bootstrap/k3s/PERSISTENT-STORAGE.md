# K3s Persistent Storage Setup

This guide explains how to set up persistent storage for K3s applications using Proxmox storage (ZFS or LVM). This provides durable storage that survives PVC deletions and VM recreation.

## Architecture

- **OS Disk**: Managed by Terraform (on `local-lvm` or similar)
- **Persistent Data Disk**: 200GB+ on Proxmox storage - managed manually for durability
  - **LVM**: `local-lvm` (recommended, matches postgres setup)
  - **ZFS**: `tank` or other ZFS pool (for advanced features)
- **Mount Point**: `/mnt/k8s-persistent` in the K3s VM
- **Storage Type**: Static PersistentVolumes with `Retain` reclaim policy

## Why Static PVs?

Unlike dynamic provisioning with `local-path`, static PVs:
- ✅ Survive PVC deletion (data remains on disk)
- ✅ Can be manually managed and backed up
- ✅ Are explicitly bound to specific paths
- ✅ Use `Retain` policy by default (no auto-deletion)

## Storage Type Selection

Choose based on your needs:

### LVM (`local-lvm`) - Recommended

**Advantages:**
- ✅ Simpler setup (direct block device)
- ✅ Matches your postgres VM setup (consistency)
- ✅ Lower latency (no network layer)
- ✅ Better performance for single-VM use
- ✅ Standard approach, well-tested

**Use when:** You want simplicity and performance (default choice)

### ZFS (`tank`) - Advanced

**Advantages:**
- ✅ Native ZFS features (snapshots, compression, checksumming)
- ✅ Better data integrity (self-healing with redundancy)
- ✅ Can be shared to multiple VMs via NFS
- ✅ Easier to resize: `zfs set quota=300G tank/k8s-persistent`
- ✅ Efficient replication: `zfs send/receive`

**Use when:** You need ZFS features or plan to share storage across VMs

**Note:** Even if using LVM, your Proxmox storage pool can be ZFS-backed, giving you pool-level benefits while keeping VM-level simplicity.

## Setup Steps

### 1. Create and Attach Disk to K3s VM

**Option A: LVM (Recommended, default)**

```bash
# On Proxmox host - create LVM disk
pvesm alloc local-lvm 112 vm-112-persistent 200G

# Attach to VM as scsi1
qm set 112 --scsi1 local-lvm:vm-112-persistent

# Verify
qm config 112 | grep scsi
```

**Option B: ZFS Dataset**

```bash
# On Proxmox host - create ZFS dataset
zfs create tank/k8s-persistent

# Set mountpoint (optional, if you want it mounted on Proxmox host)
zfs set mountpoint=/mnt/tank/k8s-persistent tank/k8s-persistent

# Create and attach disk
pvesm alloc tank 112 vm-112-persistent 200G
qm set 112 --scsi1 tank:vm-112-persistent

# Verify
zfs list | grep k8s-persistent
qm config 112 | grep scsi
```

### 2. Run Setup Script

**For LVM (default):**
```bash
cd bootstrap/k3s
./persistent-storage-setup.sh 192.168.20.11
```

**For ZFS:**
```bash
cd bootstrap/k3s
STORAGE_TYPE=zfs PROXMOX_STORAGE=tank ./persistent-storage-setup.sh 192.168.20.11
```

The script will:
1. Check SSH connectivity to K3s VM
2. Detect the attached disk
3. Format it with ext4 (if needed)
4. Mount it at `/mnt/k8s-persistent`
5. Add to `/etc/fstab` for persistence
6. Create static PersistentVolumes:
   - `werify-staging-uploads` (100Gi)
   - `werify-production-uploads` (100Gi)
   - `bugsink-data` (10Gi)
7. Create `local-path-static` StorageClass

### 4. Update PVC Manifests

Update your PVC manifests to bind to the static PVs:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: werify-uploads
  namespace: werify-staging
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path-static
  volumeName: werify-staging-uploads  # Bind to specific PV
  resources:
    requests:
      storage: 100Gi
```

**Important**: The `volumeName` field ensures the PVC binds to your static PV.

### 5. Apply Changes

```bash
# Apply updated PVCs
kubectl apply -f gitops/staging/werify/pvc.yaml
kubectl apply -f gitops/production/werify/pvc.yaml
kubectl apply -f gitops/bugsink/pvc.yaml

# Verify binding
kubectl get pv
kubectl get pvc -A
```

## Verification

```bash
# Check PVs are created and bound
kubectl get pv

# Check PVCs are bound
kubectl get pvc -A

# Check disk usage on K3s VM
ssh deployer@192.168.20.11 "df -h /mnt/k8s-persistent"

# List PV directories
ssh deployer@192.168.20.11 "ls -la /mnt/k8s-persistent/pvs/"
```

## Data Persistence

With this setup:

- ✅ **PVC deletion**: Data remains on disk (PV goes to `Released` state)
- ✅ **Pod deletion**: Data remains on disk
- ✅ **VM recreation**: Data remains on Proxmox ZFS (reattach disk to new VM)
- ✅ **Backup**: Can snapshot ZFS dataset: `zfs snapshot tank/k8s-persistent@backup-$(date +%Y%m%d)`

## Adding New PersistentVolumes

To add a new PV for another application:

1. Create directory on K3s VM:
   ```bash
   ssh deployer@192.168.20.11 "sudo mkdir -p /mnt/k8s-persistent/pvs/myapp-data"
   ssh deployer@192.168.20.11 "sudo chmod 777 /mnt/k8s-persistent/pvs/myapp-data"
   ```

2. Create PV manifest:
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: myapp-data
   spec:
     capacity:
       storage: 50Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     storageClassName: local-path-static
     local:
       path: /mnt/k8s-persistent/pvs/myapp-data
     nodeAffinity:
       required:
         nodeSelectorTerms:
         - matchExpressions:
           - key: kubernetes.io/hostname
             operator: In
             values:
             - <node-name>
   ```

3. Apply and bind PVC:
   ```bash
   kubectl apply -f myapp-pv.yaml
   # Update PVC with volumeName: myapp-data
   ```

## Troubleshooting

### Disk not detected
- Verify disk is attached: `qm config 112 | grep scsi`
- Check in VM: `ssh deployer@192.168.20.11 "lsblk"`
- May need to rescan: `echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan`

### PV not binding to PVC
- Check PV and PVC are in same namespace (PVs are cluster-scoped)
- Verify `volumeName` matches PV name exactly
- Check `storageClassName` matches
- Ensure `accessModes` match

### Permission denied in pods
- Check directory permissions: `sudo chmod 777 /mnt/k8s-persistent/pvs/<pv-name>`
- Check pod security context allows writing
- Verify SELinux/apparmor isn't blocking access

### Disk full
- Check usage: `df -h /mnt/k8s-persistent`
- Clean up old data if needed
- Consider expanding ZFS dataset: `zfs set quota=300G tank/k8s-persistent`

## Backup Strategy

1. **ZFS Snapshots** (recommended):
   ```bash
   # On Proxmox host
   zfs snapshot tank/k8s-persistent@daily-$(date +%Y%m%d)
   zfs list -t snapshot | grep k8s-persistent
   ```

2. **Manual backup**:
   ```bash
   # On K3s VM
   sudo tar -czf /tmp/k8s-persistent-backup-$(date +%Y%m%d).tar.gz /mnt/k8s-persistent/pvs/
   # Copy to backup location
   ```

3. **Application-level backups**: Use application-specific backup tools (e.g., pg_dump for databases)
