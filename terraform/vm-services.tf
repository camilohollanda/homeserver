resource "proxmox_virtual_environment_vm" "services" {
  name        = local.services_vm.name
  node_name   = var.pm_node
  vm_id       = local.services_vm.vmid
  description = "Infisical secret management server"
  tags        = split(",", local.services_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.services_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.services_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # local-lvm (SSD) — not var.storage (tank-vm HDD). The OS disk lives on
  # SSD; the Garage data disk on scsi1 below intentionally lives on tank-vm
  # for bulk object storage.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.services_vm.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Garage object data disk — backed by the 4TB ZFS pool 'tank'.
  # Mounted at /var/lib/garage/data inside the VM (handled by bootstrap/garage/install.sh).
  disk {
    datastore_id = var.tank_storage
    file_format  = "raw"
    interface    = "scsi1"
    size         = local.services_vm.garage_data_size
    discard      = "on"
    cache        = "none"
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.services_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.services_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 2
    up_delay   = 60
    down_delay = 60
  }

  depends_on = [proxmox_virtual_environment_vm.db_postgres]

  lifecycle {
    # Cloud-init only runs on first boot; YAML edits shouldn't force VM replacement.
    ignore_changes = [initialization]
  }
}

resource "proxmox_virtual_environment_file" "services_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/services.yaml")
    file_name = "services-cloud-init.yaml"
  }
}
