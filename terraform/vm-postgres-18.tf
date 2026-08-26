# PostgreSQL 18 host — active production database after the blue/green upgrade.
# It carries the same destroy protection as VM 113 did while it hosted
# production. Keep prevent_destroy enabled unless a future migration has moved
# every database elsewhere and the replacement has been verified.
#
# startup.order = 1, same as 113: databases boot in the first group. Duplicate
# orders are the norm here (k3s and postgres on 1, ai and gh-runners on 3), and
# order 2 belongs to services, which hosts Infisical — a consumer of this very
# database. Putting the database in the consumer's group would invert the boot
# dependency after cutover.
resource "proxmox_virtual_environment_vm" "db_postgres_18" {
  name        = local.db_vm_18.name
  node_name   = var.pm_node
  vm_id       = local.db_vm_18.vmid
  description = "Postgres 18 database host (blue/green target)"
  tags        = split(",", local.db_vm_18.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.db_vm_18.cores
    type  = "host"
  }

  memory {
    dedicated = local.db_vm_18.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # local-lvm (SSD) — same reasoning as VM 113: DB workloads benefit
  # significantly from SSD. Caveat: the pool sits at ~79% and is thin, so the
  # 80 GB provisioned here (20 OS + 60 data) leaves it overcommitted until 113
  # goes away. Actual usage starts around 3 GB.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.db_vm_18.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Data disk (scsi1) is managed manually in Proxmox for persistence
  # Create with: pvesm alloc local-lvm 118 vm-118-pgdata 60G
  # Then attach via Proxmox UI: VM → Hardware → Add → Hard Disk

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.db_vm_18.ip_cidr
        gateway = var.gateway
      }
    }

    user_account {
      keys     = var.ssh_public_keys
      username = var.cloud_init_user
    }

    dns {
      servers = [var.nameserver]
    }

    user_data_file_id = proxmox_virtual_environment_file.postgres_18_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 1
    up_delay   = 60
    down_delay = 60
  }

  lifecycle {
    # This VM contains the active production databases.
    prevent_destroy = true

    # - disk: ignore manually-attached data disk (scsi1) managed outside Terraform
    # - initialization: cloud-init only runs on first boot; YAML edits don't
    #   propagate to running VMs and shouldn't force replacement.
    ignore_changes = [disk, initialization]
  }
}

resource "proxmox_virtual_environment_file" "postgres_18_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/postgres-18.yaml")
    file_name = "postgres-18-cloud-init.yaml"
  }
}
