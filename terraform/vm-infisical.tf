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
    data = templatefile("${path.module}/cloud-init/infisical.yaml", {
      postgres_host             = split("/", local.db_vm.ip_cidr)[0]
      postgres_port             = 5432
      postgres_db               = var.infisical_postgres_db
      postgres_user             = var.infisical_postgres_user
      postgres_password         = var.infisical_postgres_password
      postgres_password_encoded = urlencode(var.infisical_postgres_password)
      encryption_key            = var.infisical_encryption_key
      auth_secret               = var.infisical_auth_secret
      domain                    = var.infisical_domain
      cloudflare_api_token      = var.cloudflare_api_token
      letsencrypt_email         = var.letsencrypt_email
    })
    file_name = "infisical-cloud-init.yaml"
  }
}
