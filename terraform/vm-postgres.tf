resource "proxmox_virtual_environment_vm" "db_postgres" {
  name        = local.db_vm.name
  node_name   = var.pm_node
  vm_id       = local.db_vm.vmid
  description = "Postgres database host"
  tags        = split(",", local.db_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.db_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.db_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # local-lvm (SSD) — not var.storage (tank-vm HDD). DB workloads benefit
  # significantly from SSD; the migration happened outside Terraform.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.db_vm.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Data disk (scsi1) is managed manually in Proxmox for persistence
  # Create with: pvesm alloc local-lvm 113 vm-113-pgdata 60G
  # Then attach via Proxmox UI: VM → Hardware → Add → Hard Disk

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.db_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.postgres_cloud_init.id
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
    # Protect against accidental deletion - data disk contains PostgreSQL databases
    # To intentionally destroy: temporarily set to false, apply, then destroy
    prevent_destroy = true

    # - disk: ignore manually-attached data disk (scsi1) managed outside Terraform
    # - initialization: cloud-init only runs on first boot; YAML edits don't
    #   propagate to running VMs and shouldn't force replacement.
    ignore_changes = [disk, initialization]
  }
}

resource "proxmox_virtual_environment_file" "postgres_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/postgres.yaml")
    file_name = "postgres-cloud-init.yaml"
  }
}
