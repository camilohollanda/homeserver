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
  description = "Cloud-init ready template VM ID to clone"
  type        = number
  default     = 9001
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

