# GitOps Manifests

Kubernetes manifests for Argo CD to manage applications in the cluster.

## Structure

- `minio/` - MinIO S3-compatible storage (internal use only)
- `grafana/` - Grafana observability dashboard
- `production/werify/` - Werify Phoenix LiveView application
- `argocd/` - ArgoCD Application manifests

## Usage

1. Point Argo CD Application to this repository
2. Update secrets with actual values
3. Apply via Argo CD UI or CLI

## Notes

- MinIO is not exposed via Ingress (internal S3 API only)
- Grafana is accessible via `grafana.prakash.com.br`
- Werify uses WebSocket-friendly Ingress annotations for Phoenix LiveView

### Secrets Management

Secrets are GPG-encrypted. Get the encryption key from 1Password ("Kubernetes Secrets GPG Key").

```bash
# Decrypt secrets
gpg --decrypt --output secrets.yaml secrets.yaml.gpg

# Encrypt secrets
gpg --symmetric --output secrets.yaml.gpg secrets.yaml

# Base64 encode secret values (required for Kubernetes secrets)
echo -n "super_secret_value" | base64
```

After applying secrets, restart the deployment to pick up changes.
