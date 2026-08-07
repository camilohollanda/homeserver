resource "proxmox_virtual_environment_vm" "forgejo" {
  name        = local.forgejo_vm.name
  node_name   = var.pm_node
  vm_id       = local.forgejo_vm.vmid
  description = "Forgejo — git forge, Actions control plane, OCI registry"
  tags        = split(",", local.forgejo_vm.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.forgejo_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.forgejo_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # OS disk on local-lvm (SSD) — same split as the services VM: system on SSD,
  # bulk data on the tank pool below.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.forgejo_vm.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Repos, SQLite and registry blobs — backed by the 4TB ZFS pool 'tank'.
  # Mounted at /opt/forgejo inside the VM (handled by bootstrap/forgejo/install.sh,
  # which refuses to overwrite a non-ext4 filesystem here).
  disk {
    datastore_id = var.tank_storage
    file_format  = "raw"
    interface    = "scsi1"
    size         = local.forgejo_vm.data_size
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
        address = local.forgejo_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.forgejo_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 3
    up_delay   = 60
    down_delay = 60
  }

  lifecycle {
    # Cloud-init only runs on first boot; YAML edits shouldn't force VM replacement.
    ignore_changes = [initialization]
  }
}

resource "proxmox_virtual_environment_file" "forgejo_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/forgejo.yaml")
    file_name = "forgejo-cloud-init.yaml"
  }
}
