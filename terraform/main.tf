terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.91.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "proxmox" {
  endpoint  = replace(var.pm_api_url, "/api2/json$", "")
  api_token = "${var.pm_api_token_id}=${var.pm_api_token_secret}"
  insecure = var.pm_tls_insecure
}

locals {
  # Parse SSH keys from environment variable if provided as comma-separated string
  # Terraform automatically reads TF_VAR_* environment variables
  ssh_keys = length(var.ssh_public_keys) > 0 ? var.ssh_public_keys : []

  k3s_vm = {
    name      = "k3s-apps"
    vmid      = 112
    ip_cidr   = "192.168.20.11/24"
    cores     = 8
    memory_mb = 12288
    disk_size = 80
    tags      = "k3s,apps"
  }

  db_vm = {
    name      = "db-postgres"
    vmid      = 113
    ip_cidr   = "192.168.20.21/24"
    cores     = 4
    memory_mb = 8192
    disk_size = 60
    tags      = "db,postgres"
  }
}

resource "proxmox_virtual_environment_vm" "k3s_apps" {
  name        = local.k3s_vm.name
  node_name   = var.pm_node
  vm_id       = local.k3s_vm.vmid
  description = "K3s single-node cluster host"
  tags        = split(",", local.k3s_vm.tags)

  clone {
    vm_id = var.template_vmid
    node_name = var.pm_node
    full = true
  }

  cpu {
    cores = local.k3s_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.k3s_vm.memory_mb
  }

  bios = "ovmf"
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

resource "proxmox_virtual_environment_vm" "db_postgres" {
  name        = local.db_vm.name
  node_name   = var.pm_node
  vm_id       = local.db_vm.vmid
  description = "Postgres database host"
  tags        = split(",", local.db_vm.tags)

  clone {
    vm_id = var.template_vmid
    node_name = var.pm_node
    full = true
  }

  cpu {
    cores = local.db_vm.cores
    type  = "host"
  }

  memory {
    dedicated = local.db_vm.memory_mb
  }

  bios = "ovmf"
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

output "k3s_vm_ip" {
  description = "IP address for the K3s node"
  value       = split("/", local.k3s_vm.ip_cidr)[0]
}

output "db_vm_ip" {
  description = "IP address for the Postgres node"
  value       = split("/", local.db_vm.ip_cidr)[0]
}
