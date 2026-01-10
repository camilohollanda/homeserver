# Bootstrap Scripts

Scripts to initialize the K3s cluster and install core components.

## Usage

### K3s Cluster (k3s-apps VM)

Run on the k3s-apps VM after Terraform provisioning:

```bash
sudo ./bootstrap.sh
```

**Note:** All bootstrap scripts must be run as root (using `sudo`) because they:
- Install system packages
- Configure systemd services
- Modify system files
- Access privileged ports

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
The `cloudflared-config.sh` script automates the tunnel setup using local configuration files:
- All configuration is stored locally in `/etc/cloudflared/config.yml`
- Tunnel credentials are stored in `/root/.cloudflared/`
- The script will guide you through login and tunnel creation
- DNS routes are configured automatically via CLI commands
- Service is installed and started automatically

After bootstrap, access Argo CD and configure GitOps repositories.

### Postgres Database
1. Set password for postgres user (if needed)
2. Create databases and users for your applications
3. Update application connection strings to use `db-postgres` VM IP (192.168.20.21)
