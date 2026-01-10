# HomeServer Infrastructure

Kubernetes infrastructure for Werify and Prakash.com.br, running on Proxmox with K3s, Cloudflare Tunnel, and GitOps.

## Architecture

- **Kubernetes**: K3s single-node cluster
- **Ingress**: ingress-nginx (Traefik disabled)
- **Exposure**: Cloudflare Tunnel (wildcard domains)
- **Storage**: MinIO (S3-compatible, internal)
- **Database**: Postgres (separate VM)
- **GitOps**: Argo CD
- **Observability**: Grafana

## Domains

- `werify.app` → Phoenix LiveView app (prod)
- `staging.werify.app` → Staging environment
- `grafana.prakash.com.br` → Grafana dashboard
- `prakash.com.br` → Institutional site

## Structure

```
.
├── terraform/          # Proxmox VM provisioning
├── bootstrap/          # K3s cluster initialization scripts
└── gitops/             # Argo CD application manifests
```

## Quick Start

### 1. Provision VMs

```bash
cd terraform
terraform init
terraform apply
```

### 2. Copy Bootstrap Scripts to VMs

From the terraform directory, copy bootstrap scripts to the VMs:

```bash
cd terraform
./copy-bootstrap.sh all
```

Or copy to specific VMs:
```bash
./copy-bootstrap.sh k3s      # Only k3s-apps VM
./copy-bootstrap.sh postgres # Only db-postgres VM
```

### 3. Bootstrap K3s Cluster

SSH into the k3s-apps VM and run:

```bash
ssh deployer@<k3s-vm-ip>
sudo ~/bootstrap/bootstrap.sh
```

### 4. Setup Postgres Database

SSH into the db-postgres VM and run:

```bash
ssh deployer@<db-vm-ip>
sudo ~/bootstrap/postgres-install.sh
```

Then configure databases and users as needed.

### 5. Verify Cloudflare Tunnel

The `cloudflared-config.sh` script automatically:
- Logs in to Cloudflare (opens browser for authentication)
- Creates the tunnel
- Configures DNS routes
- Installs and starts the systemd service

Check status:
```bash
systemctl status cloudflared
journalctl -u cloudflared -f
```

### 6. Access Argo CD

1. Get initial admin password:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
   ```

2. Port-forward to access Argo CD:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=0.0.0.0
   ```

3. Access Argo CD UI:
   - URL: https://localhost:8080
   - Username: `admin`
   - Password: (from step 1)

4. Create Application pointing to this repository's `gitops/` directory

## Notes

- Phoenix LiveView Ingress includes WebSocket-friendly annotations
- MinIO is not exposed publicly (internal S3 API only)
- All secrets should be updated with production values
- Cloudflare Tunnel handles TLS termination at edge
