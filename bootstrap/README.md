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
├── postgres/               # db-postgres VM (192.168.20.21) - pg.local
│   └── pg-provision.sh     # Provision databases for apps (PostgreSQL installed via cloud-init)
├── infisical/              # infisical VM (192.168.20.22)
│   └── db-setup.sh         # Run on postgres VM to create Infisical DB
├── whisper/                # whisper-gpu VM (192.168.20.30)
│   ├── setup.sh
│   └── README.md
├── media/                  # media-server VM (192.168.20.40)
│   ├── setup.sh
│   └── README.md
├── gh-runners/             # gh-runners VM (192.168.20.50)
│   ├── setup.sh
│   └── install.sh
├── forgejo/                # Forgejo VM (192.168.20.24)
│   ├── setup.sh
│   ├── install.sh
│   ├── switch-argo-source.sh
│   └── README.md
├── forgejo-runner/         # act_runner on VM 117
│   ├── setup.sh
│   └── install.sh
├── dns/                    # DNS helpers (Cloudflare Zero Trust Internal DNS)
│   └── zero-trust-internal-dns.sh
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

PostgreSQL is automatically installed and configured via cloud-init when the VM is created.
The VM is accessible at `pg.local` via mDNS (Avahi).

#### Provision App Database (run on postgres VM)

```bash
ssh deployer@192.168.20.21
/opt/bootstrap/pg-provision.sh myapp              # Creates myapp_staging DB
/opt/bootstrap/pg-provision.sh myapp --env prod   # Creates myapp_prod DB
```

This script:
- Generates a strong 32-character password
- Creates database and user with correct permissions
- Is idempotent (safe to run multiple times)
- Outputs the DATABASE_URL
- Prints the Infisical CLI command to store the secret

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

#### GitHub Actions Runners (gh-runners VM)

Self-hosted, ephemeral, JIT-registered runners (one job per process, fresh
state every time). Registered **per org** via a GitHub App — every repo in an
org draws from that org's pool.

Prerequisites:
- A GitHub App with the org permission `Self-hosted runners: Read & write`
  (plus the default `Metadata: R`), installed on every org in `GH_ORGS`.
  Per-org installation IDs are auto-discovered at runtime.

```bash
export GH_APP_CLIENT_ID=<client id>     # shown on the App's settings page
export GH_APP_PRIVATE_KEY_FILE=/path/to/app-private-key.pem
export GH_ORGS="iddh-com-br:2,prem-prakash:12"
# optional: RUNNERS_PER_ORG (default 4), RUNNER_VERSION, RUNNER_LABELS,
#           RUNNER_ERL_FLAGS, ACTIONS_RESULTS_URL

./bootstrap/gh-runners/setup.sh
```

Each `GH_ORGS` entry is `org` or `org:count`; a bare org falls back to
`RUNNERS_PER_ORG`. Size the counts from how many jobs a single push fans out
to, not from repo count — one werify PR opens three at once (`PR Checks`
splits into `check` + `sidecar`, and `Claude PR Review` is a third), so a
four-slot pool queues on the second concurrent PR.

`RUNNER_ERL_FLAGS` (default `+S 4:4`) caps the BEAM scheduler pool for every
job. Without it the BEAM opens one scheduler per core, so a single `mix test`
saturates the VM and starves every other slot.

Workflows in those orgs' repos must opt in with:

```yaml
runs-on: [self-hosted, linux, homeserver]
```

On the free plan there is only one runner group (Default), so restrict which
repos may schedule jobs under the org's Settings → Actions → Runner groups →
Repository access.

Operational:
- Status: `systemctl status 'gh-runner@*'`
- Logs:   `journalctl -u 'gh-runner@*' -f`
- Resizing a pool: update `GH_ORGS` and re-run `setup.sh` (idempotent; orphan
  instances are disabled and cleaned up).

#### Forgejo Actions failover

Forgejo runs on VM 119 and provides a warm fallback git forge, Actions control
plane and OCI registry. Its `act_runner` runs beside, but independently from,
the GitHub runners on VM 117.

```bash
# After applying Terraform for VM 119:
./bootstrap/forgejo/setup.sh

# After creating the runner registration token in Forgejo:
FORGEJO_RUNNER_TOKEN=... ./bootstrap/forgejo-runner/setup.sh

# After Forgejo has produced its initial SQLite snapshot:
./bootstrap/restic/configure.sh forgejo
```

The rollout is deliberately per application and reversible. See
`bootstrap/forgejo/README.md` for repository sync, application workflows,
secrets, preflight checks, cutover and recovery.

#### Media Server (media-server VM)

```bash
ssh deployer@192.168.20.40
sudo /opt/bootstrap/setup.sh
```

This VM is provisioned by Terraform cloud-init with a local reverse proxy:
- Jellyfin: `http://jellyfin.internal.prakash.com.br`
- qBittorrent: `http://torrent.internal.prakash.com.br`
- Radarr: `http://radarr.internal.prakash.com.br`
- Sonarr: `http://sonarr.internal.prakash.com.br`
- Prowlarr: `http://prowlarr.internal.prakash.com.br`
- Bazarr: `http://bazarr.internal.prakash.com.br`

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
│ K3s cluster     │ PostgreSQL 17→18│ Secrets mgmt  │ ML/GPU      │
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
