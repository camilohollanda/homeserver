pm_api_url            = "https://192.168.20.10:8006/api2/json"
pm_api_token_id       = "root@pam!terraform"
pm_api_token_secret   = "a596e45d-c40c-42ce-8127-70b5e78eb3b9"
pm_tls_insecure       = true

pm_node        = "server"
template_name  = "debian-13-cloudinit"
template_vmid  = 9001
storage        = "local-lvm"
bridge         = "vmbr0"
gateway        = "192.168.20.1"
nameserver     = "1.1.1.1"
searchdomain   = "home.lab"
cloud_init_user = "deployer"

ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhLzivPgJGOMkfj6Fg8WBbPvJIMLQHjpFTnXZVsncBg prakash2ji@gmail.com",
]

# Infisical configuration
# Secrets should be set via environment variables (TF_VAR_*) or .env file
# Generate secrets with:
#   openssl rand -hex 16          # for encryption_key
#   openssl rand -base64 32       # for auth_secret
#   openssl rand -base64 24       # for postgres_password
infisical_postgres_db       = "infisical"
infisical_postgres_user     = "infisical"
# infisical_postgres_password - set via TF_VAR_infisical_postgres_password
# infisical_encryption_key    - set via TF_VAR_infisical_encryption_key
# infisical_auth_secret       - set via TF_VAR_infisical_auth_secret
pm_ssh_user = "root"

# AI Services configuration (Whisper + Ollama/Qwen)
# ai_domain        - set via TF_VAR_ai_domain (e.g., ai.internal.example.com)
# ai_github_owner  - set via TF_VAR_ai_github_owner (GitHub username for whisper-api)
# ai_ghcr_token    - set via TF_VAR_ai_ghcr_token (GitHub PAT with packages:read)
# ai_ollama_model  - defaults to qwen2.5:3b (can override via TF_VAR_ai_ollama_model)
