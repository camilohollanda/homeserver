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

  disk {
    datastore_id = var.storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.db_vm.disk_size
  }

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
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 1
    up_delay   = 60
    down_delay = 60
  }
}
