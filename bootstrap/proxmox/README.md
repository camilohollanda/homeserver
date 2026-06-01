# Proxmox host (VM 110 — `server` @ 192.168.20.10)

Bare-metal hypervisor. Not in the VM inventory because it *is* the platform
the VMs run on. This folder captures the bits of the host that aren't covered
by anything else in the repo — primarily an Intel I217-LM NIC bug fix.

## What's here

- `if-up.d/disable-offloads` — disables every hardware offload on `nic0` to
  work around an e1000e packet-corruption bug (details below).
- `if-up.d/disable-eee` — disables Energy Efficient Ethernet on `nic0`, which
  causes link flaps on the same chip.
- `install.sh` — drops both scripts into `/etc/network/if-up.d/` on the PVE
  host, sets the bit, and applies the settings to the live interface.

## The NIC bug (Intel I217-LM / e1000e)

The on-board Ethernet on this Haswell-era board is an `Intel I217-LM` (PCI
`8086:153a`) driven by the `e1000e` kernel driver. With hardware offloads
enabled, large TCP transfers sporadically corrupt packets at the NIC, the
peer drops the connection, and from userspace it looks like random
`Connection reset by peer` errors mid-transfer.

Symptoms observed on this host:

- SSH sessions stalling and dropping during large `scp`/`rsync`.
- k3s image pulls failing with EOF partway through layer download.
- `restic` and `vzdump` streams aborting mid-backup.
- Argo CD sync stuck because `git fetch` of larger repos times out.

The bug has been in `e1000e` across multiple kernel revisions; upstream has
historically been slow to fix it and the only reliable workaround is to turn
off the offloads on this NIC. The fix is two `if-up.d` scripts that run every
time `nic0` comes up:

```sh
ethtool -K nic0 gso off gro off tso off lro off rx off tx off sg off rxvlan off txvlan off rxhash off
ethtool --set-eee nic0 eee off
```

To confirm the fix is active on a running host:

```sh
ethtool -k nic0 | grep -E "tcp-segmentation|generic-(segmentation|receive)|rx-checksumming|tx-checksumming"
# All five should report "off".
```

### Interface name

Proxmox renames the on-board NIC to `nic0` via
`/usr/local/lib/systemd/network/50-pmx-nic0.link` (MAC-matched). The `if-up.d`
scripts hard-code `nic0` and bail otherwise, so they're a no-op on TAP/bridge
interfaces and only fire on the physical NIC.

## What's NOT in this folder

- The Proxmox installation itself — done by the PVE ISO, not scripted.
- VM templates (9001 / 9002 / 9003) — provisioned from Terraform +
  `terraform/templates/`. The qcow2 base images live in
  `/var/lib/vz/template/cache/` on the host (~11G) and are captured by restic
  (see "Backups" below).
- The cluster config tree (`/etc/pve`) — also captured by restic.

## Backups

Per-host restic profile lives in `bootstrap/restic/configure.sh` under
`profile_proxmox`. To install/refresh:

```sh
# RESTIC_PASSWORD + S3_* env vars set (same as for services / k3s profiles)
bootstrap/restic/configure.sh proxmox
```

Paths covered:

| path                                    | why                                                      |
| --------------------------------------- | -------------------------------------------------------- |
| `/etc/pve`                              | Cluster config: VM/template `.conf`, storage, users, ACLs |
| `/etc/network`                          | `interfaces` + the `if-up.d` NIC-fix scripts             |
| `/etc/modprobe.d`                       | `vfio.conf` (GPU passthrough IDs), nvidia/microcode blacklists |
| `/etc/apt`                              | Enterprise/no-subscription repo wiring                   |
| `/usr/local/lib/systemd/network`        | `50-pmx-nic0.link` (the nic0 rename)                     |
| `/var/lib/vz/template/iso`              | qcow2 sources for the cloud-init templates (~8G; nvidia qcow2 alone is 5.3G) |

VM disk images (under LVM-thin `pve/data` and ZFS `tank-vm`) are **not**
restic'd from the host. They're rebuilt by re-running Terraform + the
per-VM bootstrap scripts, with app data restored separately via the
`services` and `k3s` restic profiles.
