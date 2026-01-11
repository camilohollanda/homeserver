variable "pm_api_url" {
  description = "Proxmox API endpoint, e.g. https://proxmox.example.com:8006/api2/json"
  type        = string
  default     = ""
}

variable "pm_api_token_id" {
  description = "Proxmox API token ID (user@realm!token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pm_tls_insecure" {
  description = "Allow insecure TLS for Proxmox API"
  type        = bool
  default     = false
}

variable "pm_node" {
  description = "Target Proxmox node name"
  type        = string
  default     = ""
}

variable "template_name" {
  description = "Cloud-init ready template name to clone"
  type        = string
  default     = ""
}

variable "template_vmid" {
  description = "Cloud-init ready template VM ID to clone (Debian 13)"
  type        = number
  default     = 9001
}

variable "template_vmid_debian12" {
  description = "Debian 12 cloud-init template VM ID (for PyTorch/GPU workloads)"
  type        = number
  default     = 9002
}

variable "template_vmid_debian12_nvidia" {
  description = "Debian 12 + NVIDIA drivers template VM ID (for GPU passthrough)"
  type        = number
  default     = 9003
}

variable "storage" {
  description = "Proxmox storage pool for disks (e.g. local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Proxmox network bridge (e.g. vmbr0)"
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "Default gateway for VMs (CIDR gateway)"
  type        = string
  default     = ""
}

variable "nameserver" {
  description = "DNS nameserver for cloud-init"
  type        = string
  default     = "1.1.1.1"
}

variable "searchdomain" {
  description = "DNS search domain for cloud-init"
  type        = string
  default     = ""
}

variable "cloud_init_user" {
  description = "Default user provisioned via cloud-init"
  type        = string
  default     = "deployer"
}

variable "ssh_public_keys" {
  description = "SSH public keys injected via cloud-init (can be set via TF_VAR_ssh_public_keys as comma-separated string or JSON array)"
  type        = list(string)
  default     = []
}

# Infisical configuration
variable "infisical_postgres_db" {
  description = "PostgreSQL database name for Infisical"
  type        = string
  default     = "infisical"
}

variable "infisical_postgres_user" {
  description = "PostgreSQL username for Infisical"
  type        = string
  default     = "infisical"
}

variable "infisical_postgres_password" {
  description = "PostgreSQL password for Infisical"
  type        = string
  sensitive   = true
}

variable "infisical_encryption_key" {
  description = "Infisical encryption key (32 hex chars). Generate with: openssl rand -hex 16"
  type        = string
  sensitive   = true
}

variable "infisical_auth_secret" {
  description = "Infisical auth secret for JWT signing. Generate with: openssl rand -base64 32"
  type        = string
  sensitive   = true
}

variable "infisical_site_url" {
  description = "Public URL for Infisical (e.g., https://secrets.example.com)"
  type        = string
  default     = ""
}

variable "snippets_storage" {
  description = "Proxmox storage for cloud-init snippets (must have 'snippets' content type enabled)"
  type        = string
  default     = "local"
}

variable "pm_ssh_user" {
  description = "SSH username for Proxmox host (for uploading cloud-init snippets)"
  type        = string
  default     = "root"
}

variable "infisical_tls_cert" {
  description = "TLS certificate for Infisical (PEM format). Generate with: mkcert infisical.local"
  type        = string
  default     = ""
  sensitive   = true
}

variable "infisical_tls_key" {
  description = "TLS private key for Infisical (PEM format)"
  type        = string
  default     = ""
  sensitive   = true
}
