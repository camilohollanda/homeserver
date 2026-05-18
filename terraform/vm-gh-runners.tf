resource "proxmox_virtual_environment_vm" "gh_runners" {
  name        = local.gh_runners_vm.name
  node_name   = var.pm_node
  vm_id       = local.gh_runners_vm.vmid
  description = "GitHub Actions self-hosted runners (ephemeral, JIT-registered per repo)"
  tags        = split(",", local.gh_runners_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.gh_runners_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.gh_runners_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # CI workload is many-small-files I/O — pinned to local-lvm (SSD-backed)
  # rather than the default var.storage (tank-vm, 7200 RPM HDD) to avoid
  # head-thrash when multiple ephemeral runners build concurrently.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.gh_runners_vm.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.gh_runners_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.gh_runners_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 3
    up_delay   = 60
    down_delay = 60
  }
}

resource "proxmox_virtual_environment_file" "gh_runners_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/gh-runners.yaml")
    file_name = "gh-runners-cloud-init.yaml"
  }
}
