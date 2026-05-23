# Terraform Configuration for Proxmox VMs

This directory contains Terraform configuration to provision VMs on Proxmox:
- **k3s-apps** (192.168.20.11) - K3s single-node cluster
- **db-postgres** (192.168.20.21) - PostgreSQL database server
- **infisical** (192.168.20.22) - Infisical secret management server
- **ai-gpu** (192.168.20.30) - Whisper + Ollama services
- **media-server** (192.168.20.40) - Jellyfin + qBittorrent + Radarr + Sonarr stack

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
./copy-bootstrap.sh media    # Only media-server VM
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

### Media stack

The media server (Jellyfin + qBittorrent + Radarr + Sonarr) is deployed by Terraform through:

- `terraform/vm-media.tf` - VM definition
- `terraform/cloud-init/media.yaml` - container stack and service bootstrap
- `bootstrap/media` - manual helper scripts and docs

The media VM exposes these services via a local reverse proxy (no ports):
- `http://jellyfin.internal.prakash.com.br`
- `http://torrent.internal.prakash.com.br`
- `http://radarr.internal.prakash.com.br`
- `http://sonarr.internal.prakash.com.br`
- `http://prowlarr.internal.prakash.com.br`
- `http://bazarr.internal.prakash.com.br`

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

## Cloudflare resources

DNS records and the cloudflared tunnel (including its ingress routes) are
managed here:

- `cloudflare-tunnel.tf` — the `homeserver` tunnel + its remotely-managed
  ingress block. The on-VM `/etc/cloudflared/config.yml` contains only
  `tunnel:` + `credentials-file:` — all ingress routes come from Cloudflare
  and live-reload on `terraform apply`.
- `cloudflare-dns.tf` — public CNAMEs at the tunnel and internal A-records
  for LAN-only services on `*.internal.prakash.com.br` (those records live
  inside the `prakash.com.br` zone, not a separate delegated zone).

### Token model — two tokens, different scopes

Cloudflare access is split across two tokens. The split is intentional —
compromise of one shouldn't grant the powers of the other.

| Token | Env var | Scope | Where it lives | What it does |
|---|---|---|---|---|
| **A — narrow** | `CF_API_TOKEN` | `Zone.DNS:Edit` + `Zone:Read` on the 3 zones | `.env` on dev box AND `/etc/letsencrypt/cloudflare.ini` on every VM that uses certbot DNS-01 | certbot's `_acme-challenge.*` TXT writes; nothing else |
| **B — broad** | `TF_VAR_cloudflare_api_token` | A's scopes **plus** `Account.Cloudflare Tunnel:Edit` | `.env` on dev box only — **never copy to a VM** | Terraform provider |

Why this matters:
- If a VM is compromised, the attacker can edit DNS but cannot touch the
  tunnel ingress — they can't, e.g., redirect routes to themselves.
- If the dev box is compromised, the attacker gets the broader token, but
  that's a smaller and more controllable attack surface than 3+ VMs.
- To rotate Token B alone: create a new token in CF dashboard with the same
  permissions, swap value of `TF_VAR_cloudflare_api_token` in `.env`, delete
  the old token. No SSH to any VM. Same recipe for Token A in reverse — but
  rotating A also requires updating `/etc/letsencrypt/cloudflare.ini` on
  each VM (currently 3: services, ai, postgres) and restarting certbot.

### Operational quirks worth knowing

- **`config_src` is `ForceNew` in the CF Terraform provider** — but the CF
  API itself supports changing it in place. If you ever need to flip a
  tunnel between locally-managed and remotely-managed, do it via the API
  (`PATCH /accounts/X/cfd_tunnel/Y` with `{"config_src": "..."}`), then
  `terraform state rm` + `terraform import` the tunnel to refresh state.
  Letting Terraform handle the change would destroy + recreate the tunnel
  — new UUID, new credentials JSON, manual cloudflared rewrite on the VM.
- **Pre-populate the remote-managed config before flipping `config_src`**.
  When you set `config_src=cloudflare`, cloudflared starts pulling its
  ingress from CF's stored config — if that store is empty, every request
  returns 404 until you push a config. Order: PUT the config first, THEN
  patch `config_src`.
- **`internal.prakash.com.br` is not a zone** — those A records live inside
  the `prakash.com.br` zone with multi-segment names. The older bash
  scripts hardcoded a zone ID that happened to be `prakash.com.br`'s.
- **CF token permission changes take a few seconds to propagate** across
  CF's edges. If Terraform 403s on a tunnel read immediately after you
  add a scope to the token, retry once — it usually clears within a minute.

### Ongoing changes — the everyday workflow

- **Add a route to the tunnel** → edit `local.tunnel_ingress` in
  `cloudflare-tunnel.tf`. Cloudflared live-reloads on the next apply; no SSH.
- **Add an internal service** → add an entry to `local.internal_a_records` in
  `cloudflare-dns.tf`.
- **Add a public hostname** → add to `local.public_tunnel_records` AND to
  `local.tunnel_ingress` (CNAME alone is not enough; the tunnel needs to
  know what to route the host to).
- **`bootstrap/k3s/cloudflared-config.sh`** is still used for first-time
  cloudflared install on a fresh k3s VM — it now only writes the minimal
  config (tunnel ID + credentials path) and registers the systemd service.

## Notes

- The `.env` file is gitignored and contains sensitive information
- State files are also gitignored
- Use `terraform.tfvars` as an alternative if you prefer (also gitignored)
- `terraform.tfstate` and `terraform.tfvars` were previously tracked in git;
  they have been untracked. Existing committed history still contains secrets —
  rotate sensitive values (Proxmox token, CF token, Infisical encryption key,
  etc.) at your convenience as a follow-up.
