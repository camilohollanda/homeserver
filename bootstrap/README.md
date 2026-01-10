# Bootstrap Scripts

Scripts to initialize the K3s cluster and install core components.

## Usage

Run on the k3s-apps VM after Terraform provisioning:

```bash
sudo ./bootstrap.sh
```

## Components

- `k3s-install.sh` - Installs K3s with Traefik disabled
- `ingress-nginx-install.sh` - Installs ingress-nginx controller
- `argocd-install.sh` - Installs Argo CD for GitOps
- `cloudflared-install.sh` - Installs cloudflared binary
- `cloudflared-config.sh` - Configures cloudflared systemd service

## Post-Install

1. Create Cloudflare Tunnel and get credentials
2. Place credentials at `/etc/cloudflared/credentials.json`
3. Update `TUNNEL_ID` in `/etc/cloudflared/config.yml`
4. Enable cloudflared: `systemctl enable --now cloudflared`
5. Access Argo CD and configure GitOps repositories
