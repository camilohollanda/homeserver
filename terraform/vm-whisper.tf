resource "proxmox_virtual_environment_vm" "whisper_gpu" {
  name        = local.whisper_vm.name
  node_name   = var.pm_node
  vm_id       = local.whisper_vm.vmid
  description = "Whisper AI inference server with GPU passthrough"
  tags        = split(",", local.whisper_vm.tags)

  clone {
    vm_id     = var.template_vmid_debian12_nvidia  # Debian 12 + NVIDIA drivers pre-installed
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.whisper_vm.cores
    type  = "host" # Required for GPU passthrough
  }

  memory {
    dedicated = local.whisper_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  # Disable Secure Boot - required for NVIDIA drivers (unsigned kernel modules)
  efi_disk {
    datastore_id      = var.storage
    pre_enrolled_keys = false
    type              = "4m"
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.whisper_vm.disk_size
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  # GPU Passthrough - Quadro M4000 (uses resource mapping)
  hostpci {
    device  = "hostpci0"
    mapping = local.whisper_vm.gpu_mapping
    pcie    = true
    rombar  = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.whisper_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.whisper_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 3
    up_delay   = 120 # Give time for GPU initialization
    down_delay = 60
  }
}

resource "proxmox_virtual_environment_file" "whisper_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data = file("${path.module}/cloud-init/whisper.yaml")
    file_name = "whisper-cloud-init.yaml"
  }
}
