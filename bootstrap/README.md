# Bootstrap Scripts

Scripts organized by VM to initialize infrastructure components.

## Folder Structure

```
bootstrap/
├── k3s/                    # k3s-apps VM (192.168.20.11)
│   ├── bootstrap.sh        # Main orchestrator - run this!
│   ├── k3s-install.sh
│   ├── ingress-nginx-install.sh
│   ├── argocd-install.sh
│   ├── argocd-github-setup.sh
│   ├── argocd-image-updater-install.sh
│   ├── external-secrets-install.sh
│   ├── cert-manager-install.sh
│   ├── cloudflared-install.sh
│   ├── cloudflared-config.sh
│   └── ARGOCD-DOMAIN.md
├── postgres/               # db-postgres VM (192.168.20.21)
│   └── install.sh
├── infisical/              # infisical VM (192.168.20.22)
│   └── db-setup.sh         # Run on postgres VM to create Infisical DB
├── whisper/                # whisper-gpu VM (192.168.20.30)
│   ├── setup.sh
│   └── README.md
└── README.md               # This file
```

## Quick Start

### 1. Copy Scripts to VMs

From your local machine (in the terraform directory):

```bash
./copy-bootstrap.sh all
```

This copies the appropriate scripts to each VM at `/opt/bootstrap/`.

### 2. Bootstrap Each VM

#### K3s Cluster (k3s-apps VM)

```bash
ssh deployer@192.168.20.11
sudo /opt/bootstrap/bootstrap.sh
```

This installs everything in the correct order:
- K3s (lightweight Kubernetes)
- ingress-nginx
- ArgoCD
- External Secrets Operator
- ArgoCD Image Updater
- Cloudflare Tunnel

#### PostgreSQL (db-postgres VM)

```bash
ssh deployer@192.168.20.21
sudo /opt/bootstrap/install.sh
```

#### Infisical Database (run on postgres VM)

```bash
ssh deployer@192.168.20.21
/opt/bootstrap/db-setup.sh infisical infisical 'your-secure-password'
```

#### Whisper GPU (whisper-gpu VM)

```bash
ssh deployer@192.168.20.30
sudo /opt/bootstrap/setup.sh
# Reboot if prompted for NVIDIA driver, then run again
```

## Post-Bootstrap Steps (K3s)

### 1. Create Infisical Credentials

```bash
kubectl create secret generic infisical-credentials \
  --namespace external-secrets \
  --from-literal=clientId="$INFISICAL_CLIENT_ID" \
  --from-literal=clientSecret="$INFISICAL_CLIENT_SECRET"
```

### 2. Configure GitHub Access for ArgoCD

```bash
sudo /opt/bootstrap/argocd-github-setup.sh
```

### 3. Access ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Access via NodePort
https://192.168.20.11:30443
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         VMs                                      │
├─────────────────┬─────────────────┬─────────────────────────────┤
│   k3s-apps      │   db-postgres   │   infisical   │ whisper-gpu │
│  192.168.20.11  │  192.168.20.21  │ 192.168.20.22 │ .20.30      │
├─────────────────┼─────────────────┼───────────────┼─────────────┤
│ K3s cluster     │ PostgreSQL 17   │ Secrets mgmt  │ ML/GPU      │
│ ArgoCD          │ Databases for:  │ (Docker)      │ Whisper API │
│ ingress-nginx   │ - Infisical     │               │             │
│ External Secrets│ - Apps          │               │             │
│ Cloudflare Tun. │                 │               │             │
└─────────────────┴─────────────────┴───────────────┴─────────────┘
```

## Troubleshooting

### K3s Cluster

```bash
# Check all pods
kubectl get pods -A

# External Secrets logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# ArgoCD Image Updater logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater

# Cloudflare Tunnel
systemctl status cloudflared
journalctl -u cloudflared -f
```

### PostgreSQL

```bash
# Check service status
systemctl status postgresql

# Connect to database
sudo -u postgres psql
```

### Whisper GPU

```bash
# Check GPU
nvidia-smi

# Check service
systemctl status whisper-api
curl http://localhost:8000/health
```
