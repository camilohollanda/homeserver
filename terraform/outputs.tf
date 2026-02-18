output "k3s_vm_ip" {
  description = "IP address for the K3s node"
  value       = split("/", local.k3s_vm.ip_cidr)[0]
}

output "db_vm_ip" {
  description = "IP address for the Postgres node"
  value       = split("/", local.db_vm.ip_cidr)[0]
}

output "infisical_vm_ip" {
  description = "IP address for the Infisical node"
  value       = split("/", local.infisical_vm.ip_cidr)[0]
}

output "infisical_url" {
  description = "URL to access Infisical UI"
  value       = "https://${split("/", local.infisical_vm.ip_cidr)[0]}:8443"
}

output "ai_vm_ip" {
  description = "IP address for the Whisper GPU inference server"
  value       = split("/", local.ai_vm.ip_cidr)[0]
}

output "whisper_api_url" {
  description = "URL for Whisper transcription API"
  value       = "http://${split("/", local.ai_vm.ip_cidr)[0]}:8000"
}
