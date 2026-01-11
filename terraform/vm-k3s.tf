resource "proxmox_virtual_environment_vm" "k3s_apps" {
  name        = local.k3s_vm.name
  node_name   = var.pm_node
  vm_id       = local.k3s_vm.vmid
  description = "K3s single-node cluster host"
  tags        = split(",", local.k3s_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.k3s_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.k3s_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.k3s_vm.disk_size
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.k3s_vm.ip_cidr
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
