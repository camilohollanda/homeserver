resource "proxmox_virtual_environment_vm" "media_server" {
  name        = local.media_vm.name
  node_name   = var.pm_node
  vm_id       = local.media_vm.vmid
  description = "Media stack host (Jellyfin + qBittorrent + Radarr + Sonarr)"
  tags        = split(",", local.media_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.media_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.media_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.media_vm.disk_size
    discard      = "on"
    # ssd=false: this VM lives on tank-vm (HDD) by design — bulk media on
    # 4TB spinning storage. Tell the guest it's rotational so the kernel
    # picks an HDD-appropriate I/O scheduler.
    ssd      = false
    iothread = true
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.media_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.media_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 4
    up_delay   = 120
    down_delay = 60
  }

  lifecycle {
    # Cloud-init only runs on first boot; YAML edits shouldn't force VM replacement.
    ignore_changes = [initialization]
  }
}

resource "proxmox_virtual_environment_file" "media_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/media.yaml")
    file_name = "media-cloud-init.yaml"
  }
}
