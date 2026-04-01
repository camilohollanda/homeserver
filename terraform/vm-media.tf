resource "proxmox_virtual_environment_vm" "media_server" {
  name        = local.media_vm.name
  node_name   = var.pm_node
  vm_id       = local.media_vm.vmid
  description = "Media stack host (Jellyfin + qBittorrent + Radarr)"
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
}

resource "proxmox_virtual_environment_file" "media_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data = templatefile("${path.module}/cloud-init/media.yaml", {
      media_library_path   = var.media_library_path
      media_download_path  = var.media_download_path
      media_timezone      = var.media_timezone
      media_uid          = var.media_uid
      media_gid          = var.media_gid
      media_jellyfin_domain   = var.media_jellyfin_domain
      media_qbittorrent_domain = var.media_qbittorrent_domain
      media_radarr_domain     = var.media_radarr_domain
    })
    file_name = "media-cloud-init.yaml"
  }
}
