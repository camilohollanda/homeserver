# Terraform Configuration for Proxmox VMs

This directory contains Terraform configuration to provision VMs on Proxmox:
- **k3s-apps** (192.168.20.11) - K3s single-node cluster
- **db-postgres** (192.168.20.21) - PostgreSQL database server
- **infisical** (192.168.20.22) - Infisical secret management server

## Prerequisites

- Terraform >= 1.6.0
- `mise` (for environment variable management)
- Access to Proxmox API

## Setup

1. Copy `.env.sample` to `.env`:
   ```bash
   cp .env.sample .env
   ```

2. Edit `.env` with your actual values:
   - Update `TF_VAR_pm_api_token_secret` with your Proxmox API token
   - Adjust network settings if needed
   - Update SSH public keys

3. `mise` will automatically load the `.env` file when you enter the directory.

4. Initialize Terraform:
   ```bash
   terraform init
   ```

5. Review the plan:
   ```bash
   terraform plan
   ```

6. Apply the configuration:
   ```bash
   terraform apply
   ```

7. Copy bootstrap scripts to VMs:
   ```bash
   ./copy-bootstrap.sh all
   ```

   Or copy to specific VMs:
   ```bash
   ./copy-bootstrap.sh k3s      # Only k3s-apps VM
   ./copy-bootstrap.sh postgres # Only db-postgres VM
   ```

## Environment Variables

All configuration is done via environment variables with the `TF_VAR_` prefix. Terraform automatically reads these.

For list variables like `ssh_public_keys`, use JSON array format:
```bash
TF_VAR_ssh_public_keys='["key1","key2"]'
```

## Files

- `main.tf` - Main Terraform configuration
- `variables.tf` - Variable definitions
- `.env.sample` - Example environment variables (safe to commit)
- `.env` - Your actual environment variables (gitignored)
- `.gitignore` - Excludes sensitive files from git

## Infisical Setup

The Infisical VM requires additional setup after Terraform provisions the VMs:

### 1. Generate Secrets

Before applying Terraform, generate the required secrets:

```bash
# Generate encryption key (32 hex chars)
openssl rand -hex 16

# Generate auth secret
openssl rand -base64 32

# Generate postgres password
openssl rand -base64 24
```

Update these values in `terraform.tfvars`.

### 2. Setup PostgreSQL Database

After the VMs are created, SSH into the db-postgres VM and run:

```bash
# On db-postgres VM (192.168.20.21)
cd /opt/bootstrap
./infisical-db-setup.sh infisical infisical 'your-postgres-password'
```

Then configure PostgreSQL to accept remote connections:

```bash
# Edit postgresql.conf
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf

# Add to pg_hba.conf
echo "host    infisical    infisical    192.168.20.22/32    scram-sha-256" | sudo tee -a /etc/postgresql/*/main/pg_hba.conf

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### 3. Access Infisical

After the Infisical VM boots (takes ~3-5 minutes for Docker setup):

- URL: https://192.168.20.22:8443
- Create your admin account on first login
- The self-signed certificate will show a warning (expected)

### 4. Integrate with K8s

Install External Secrets Operator on your K3s cluster:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

## Notes

- The `.env` file is gitignored and contains sensitive information
- State files are also gitignored
- Use `terraform.tfvars` as an alternative if you prefer (also gitignored)
