# Bootstrap Scripts

Scripts to initialize the K3s cluster and install core infrastructure components.

## Quick Start

### K3s Cluster (k3s-apps VM)

Run on the k3s-apps VM after Terraform provisioning:

```bash
sudo ./bootstrap.sh
```

This single command installs everything in the correct order.

## What Gets Installed

The bootstrap process installs infrastructure in 3 phases:

### Phase 1: Core Infrastructure
| Component | Script | Description |
|-----------|--------|-------------|
| K3s | `k3s-install.sh` | Lightweight Kubernetes (Traefik disabled) |
| ingress-nginx | `ingress-nginx-install.sh` | Ingress controller |
| ArgoCD | `argocd-install.sh` | GitOps controller |

### Phase 2: Operators (via Helm)
| Component | Script | Description |
|-----------|--------|-------------|
| External Secrets | `external-secrets-install.sh` | Syncs secrets from Infisical |
| ArgoCD Image Updater | `argocd-image-updater-install.sh` | Auto-updates container images |

### Phase 3: Networking
| Component | Script | Description |
|-----------|--------|-------------|
| cloudflared | `cloudflared-install.sh` | Cloudflare Tunnel binary |
| Tunnel config | `cloudflared-config.sh` | Configures tunnel service |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Bootstrap (run once)                      │
│  Installs: K3s, ArgoCD, ingress-nginx, operators, tunnel    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     GitOps (continuous)                      │
│  Manages: Apps, secrets config, observability stack          │
│  Location: gitops/                                           │
└─────────────────────────────────────────────────────────────┘
```

**Why Helm in bootstrap?**

Operators like External Secrets and ArgoCD Image Updater are 30K+ lines of CRDs,
RBAC, webhooks, and controllers. They're infrastructure installed once, not
application configs that change frequently. Helm is appropriate for this.

GitOps manages your apps and their configurations (ClusterSecretStore,
ExternalSecrets, ImageUpdater CRs) - those are self-contained YAML manifests.

## Post-Bootstrap Steps

### 1. Create Infisical Credentials

```bash
kubectl create secret generic infisical-credentials \
  --namespace external-secrets \
  --from-literal=clientId="$INFISICAL_CLIENT_ID" \
  --from-literal=clientSecret="$INFISICAL_CLIENT_SECRET"
```

### 2. Configure GitHub Access for ArgoCD

```bash
sudo ./argocd-github-setup.sh
```

This sets up either:
- SSH Deploy Key (single repository)
- GitHub App (multiple repositories)

### 3. Access ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Access via NodePort
https://192.168.20.11:30443
```

### 4. Apply GitOps Configuration

In ArgoCD, create an Application pointing to your `gitops/` directory.

## Other Scripts

### Database (db-postgres VM)

```bash
# Install PostgreSQL 16 (default)
sudo ./postgres-install.sh

# Or specific version
POSTGRES_VERSION=15 sudo ./postgres-install.sh
```

### Infisical Database Setup

```bash
sudo ./infisical-db-setup.sh
```

### Whisper GPU Setup

See `WHISPER-GPU.md` for GPU-accelerated transcription setup.

## Troubleshooting

### Check all pods
```bash
kubectl get pods -A
```

### Check operator logs
```bash
# External Secrets
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# ArgoCD Image Updater
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater
```

### Cloudflare Tunnel
```bash
systemctl status cloudflared
journalctl -u cloudflared -f
```

## Notes

- All scripts must be run as root (`sudo`)
- ArgoCD works without a public domain (polling every 3 min)
- For immediate GitHub webhook sync, see `ARGOCD-DOMAIN.md`
