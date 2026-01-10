# Terraform Configuration for Proxmox VMs

This directory contains Terraform configuration to provision K3s and Postgres VMs on Proxmox.

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

## Notes

- The `.env` file is gitignored and contains sensitive information
- State files are also gitignored
- Use `terraform.tfvars` as an alternative if you prefer (also gitignored)
