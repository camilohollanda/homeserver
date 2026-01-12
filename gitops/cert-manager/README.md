# Internal Services TLS Setup

This setup provides valid Let's Encrypt certificates for internal services using DNS-01 challenge via Cloudflare. Services remain **private** (not exposed to the internet) while having trusted HTTPS.

## How it Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE DNS                          │
│                                                                 │
│  *.internal.prakash.com.br  →  A  →  192.168.20.11 (private)   │
│                                                                 │
│  cert-manager creates TXT records for DNS-01 validation        │
│  Let's Encrypt verifies ownership via DNS (no HTTP required)   │
└─────────────────────────────────────────────────────────────────┘

Result:
  ✅ Valid Let's Encrypt certificate
  ✅ Only accessible from local network
  ❌ NOT exposed to internet
```

## Setup Steps

### 1. Install cert-manager on k3s

```bash
ssh k3s-apps
sudo /opt/bootstrap/cert-manager-install.sh
```

### 2. Create Cloudflare API Token

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create a token with these permissions:
   - **Zone:DNS:Edit** for `prakash.com.br`
3. Save the token

### 3. Store Token in Infisical

Create a secret in Infisical:
- **Path**: `/shared/`
- **Key**: `cloudflare-api-token`
- **Value**: Your API token

### 4. Create DNS A Record in Cloudflare

Create a wildcard A record pointing to your k3s internal IP:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | *.internal | 192.168.20.11 | ❌ DNS only |

This makes all `*.internal.prakash.com.br` subdomains resolve to your k3s server.

### 5. Push Changes and Let ArgoCD Sync

The gitops changes will automatically:
1. Deploy cert-manager configuration
2. Create the ClusterIssuer
3. Request wildcard certificate from Let's Encrypt
4. cert-manager creates DNS TXT record for validation
5. Let's Encrypt verifies and issues certificate
6. Ingresses get valid TLS

## Internal Services

After setup, these services will be available with valid HTTPS:

| Service | URL |
|---------|-----|
| Bugsink | https://bugsink.internal.prakash.com.br |
| Grafana | https://grafana.internal.prakash.com.br |
| ArgoCD | https://argocd.internal.prakash.com.br |
| Infisical | https://infisical.internal.prakash.com.br |

## Adding More Internal Services

To add TLS to a new internal service, update its ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-dns
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - my-service.internal.prakash.com.br
      secretName: my-service-tls
  rules:
    - host: my-service.internal.prakash.com.br
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

## Troubleshooting

### Check certificate status
```bash
kubectl get certificates -A
kubectl describe certificate internal-wildcard -n cert-manager
```

### Check cert-manager logs
```bash
kubectl logs -n cert-manager -l app=cert-manager
```

### Check if DNS challenge was created
```bash
kubectl get challenges -A
```
