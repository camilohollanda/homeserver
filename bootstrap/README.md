# Bootstrap Scripts

Scripts to initialize the K3s cluster and install core components.

## Usage

### K3s Cluster (k3s-apps VM)

Run on the k3s-apps VM after Terraform provisioning:

```bash
sudo ./bootstrap.sh
```

### Postgres Database (db-postgres VM)

Run on the db-postgres VM after Terraform provisioning:

```bash
# Install default version (PostgreSQL 16)
sudo ./postgres-install.sh

# Or install a specific version
POSTGRES_VERSION=15 sudo ./postgres-install.sh
POSTGRES_VERSION=14 sudo ./postgres-install.sh
```

## Components

### K3s Cluster
- `k3s-install.sh` - Installs K3s with Traefik disabled
- `ingress-nginx-install.sh` - Installs ingress-nginx controller
- `argocd-install.sh` - Installs Argo CD for GitOps
- `cloudflared-install.sh` - Installs cloudflared binary
- `cloudflared-config.sh` - Configures cloudflared systemd service
- `bootstrap.sh` - Orchestrates all K3s cluster setup

### Database
- `postgres-install.sh` - Installs and configures PostgreSQL

## Post-Install

### K3s Cluster
1. Create Cloudflare Tunnel and get credentials
2. Place credentials at `/etc/cloudflared/credentials.json`
3. Update `TUNNEL_ID` in `/etc/cloudflared/config.yml`
4. Enable cloudflared: `systemctl enable --now cloudflared`
5. Access Argo CD and configure GitOps repositories

### Postgres Database
1. Set password for postgres user (if needed)
2. Create databases and users for your applications
3. Update application connection strings to use `db-postgres` VM IP (192.168.20.21)
