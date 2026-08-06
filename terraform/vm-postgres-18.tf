# PostgreSQL 18 host — destino do upgrade blue/green.
# Espelha vm-postgres.tf (VM 113). Duas diferenças deliberadas:
#   - prevent_destroy = false: durante a Fase A esta VM não guarda nada, e
#     iterar sobre ela precisa ser barato. Vira true no cutover, quando passa a
#     ser o banco de produção.
#   - startup.order = 2: sobe depois da 113, que ainda é a produção.
resource "proxmox_virtual_environment_vm" "db_postgres_18" {
  name        = local.db_vm_18.name
  node_name   = var.pm_node
  vm_id       = local.db_vm_18.vmid
  description = "Postgres 18 database host (blue/green target)"
  tags        = split(",", local.db_vm_18.tags)

  clone {
    vm_id     = var.template_vmid
    node_name = var.pm_node
    full      = true
  }

  cpu {
    cores = local.db_vm_18.cores
    type  = "host"
  }

  memory {
    dedicated = local.db_vm_18.memory_mb
  }

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware = "virtio-scsi-single"

  # local-lvm (SSD) — mesmo raciocínio da VM 113: workload de banco ganha
  # bastante com SSD. Atenção: o pool está em ~79% e é thin, então os 80 GB
  # provisionados (20 OS + 60 dados) ficam sobrecomprometidos até a 113 sair.
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = local.db_vm_18.disk_size
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Data disk (scsi1) is managed manually in Proxmox for persistence
  # Create with: pvesm alloc local-lvm 118 vm-118-pgdata 60G
  # Then attach via Proxmox UI: VM → Hardware → Add → Hard Disk

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = local.db_vm_18.ip_cidr
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

    user_data_file_id = proxmox_virtual_environment_file.postgres_18_cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = 2
    up_delay   = 60
    down_delay = 60
  }

  lifecycle {
    # Fase A: a VM é descartável enquanto não houver dado real nela.
    # No cutover, trocar para true (a 113 usa true pelo mesmo motivo).
    prevent_destroy = false

    # - disk: ignore manually-attached data disk (scsi1) managed outside Terraform
    # - initialization: cloud-init only runs on first boot; YAML edits don't
    #   propagate to running VMs and shouldn't force replacement.
    ignore_changes = [disk, initialization]
  }
}

resource "proxmox_virtual_environment_file" "postgres_18_cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippets_storage
  node_name    = var.pm_node

  source_raw {
    data      = file("${path.module}/cloud-init/postgres-18.yaml")
    file_name = "postgres-18-cloud-init.yaml"
  }
}
