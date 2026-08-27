resource "proxmox_virtual_environment_vm" "ai_gpu" {
  name        = local.ai_vm.name
  node_name   = var.pm_node
  vm_id       = local.ai_vm.vmid
  description = "AI inference server (Whisper + Ollama) with GPU passthrough"
  tags        = split(",", local.ai_vm.tags)

  clone {
    vm_id     = var.template_vmid_debian12_nvidia # Debian 12 + NVIDIA drivers pre-installed
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.ai_vm.cores
    type  = "host" # Required for GPU passthrough
  }

  memory {
    dedicated = local.ai_vm.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  # Disable Secure Boot - required for NVIDIA drivers (unsigned kernel modules)
  # Stays on local-lvm: it is 4 MB of firmware variables, read once at boot, so
  # it did not follow scsi0 to tank-vm.
  efi_disk {
    datastore_id      = "local-lvm"
    pre_enrolled_keys = false
    type              = "4m"
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    # var.tank_storage (HDD) — not var.storage (local-lvm SSD). Moved off
    # local-lvm outside Terraform, reversing the earlier "models on faster
    # media" call: the SSD thin pool was the scarce resource and this is the
    # largest OS disk that did not need it. Model loads come off spinning disk
    # now, which costs a slower first load; once a model is resident in the
    # M4000's VRAM the disk is out of the path entirely.
    #
    # ssd=false for the same reason as the media VM: `tank` is one 3.6TB 7200rpm
    # drive. The host still carries ssd=1 here — the flag survived the storage
    # move — so this is the one disk attribute where config and host disagree
    # until the next apply. Every other tank-vm disk on the host (114 scsi1,
    # 116 scsi0) is already ssd=0.
    datastore_id = var.tank_storage
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.ai_vm.disk_size
    discard      = "on"
    ssd          = false
    iothread     = true
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  # GPU Passthrough - Quadro M4000 (uses resource mapping)
  hostpci {
    device  = "hostpci0"
    mapping = local.ai_vm.gpu_mapping
    pcie    = true
    rombar  = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.ai_vm.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.ai_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 3
    up_delay   = 120 # Give time for GPU initialization
    down_delay = 60
  }

  lifecycle {
    # Cloud-init only runs on first boot; YAML edits shouldn't force VM replacement.
    ignore_changes = [initialization]
  }
}

resource "proxmox_virtual_environment_file" "ai_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/ai.yaml")
    file_name = "ai-cloud-init.yaml"
  }
}
