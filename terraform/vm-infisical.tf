resource "proxmox_virtual_environment_vm" "infisical" {
  name        = local.infisical_vm.name
  node_name   = var.pm_node
  vm_id       = local.infisical_vm.vmid
  description = "Infisical secret management server"
  tags        = split(",", local.infisical_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.infisical_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.infisical_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.infisical_vm.disk_size
  }

  # Garage object data disk — backed by the 4TB ZFS pool 'tank'.
  # Mounted at /var/lib/garage/data inside the VM (handled by bootstrap/garage/install.sh).
  disk {
    datastore_id = var.tank_storage
    file_format  = "raw"
    interface    = "scsi1"
    size         = local.infisical_vm.garage_data_size
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
        address = local.infisical_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.infisical_cloud_init.id
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
}

resource "proxmox_virtual_environment_file" "infisical_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/infisical.yaml")
    file_name = "infisical-cloud-init.yaml"
  }
}
