#!/usr/bin/env bash
# Usage: ./scripts/new-app.sh --domain myapp.com --repo ghcr.io/owner/myapp [OPTIONS]
#
# Options:
#   -d, --domain        Domain name for the app (e.g. myapp.com or app.prakash.com.br)
#   -r, --repo          Container image (e.g. ghcr.io/owner/myapp)
#   -n, --name          App name slug (default: derived from repo basename)
#   -p, --port          Container port (default: 80)
#   -t, --tag           Image tag (default: main)
#       --storage       Add persistent storage, e.g. --storage 10Gi:/app/uploads
#       --no-ghcr       Skip GHCR pull secret (image is public or not on GHCR)
#       --dry-run       Print files to stdout instead of writing them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOMAIN=""
IMAGE=""
APP_NAME=""
PORT="80"
TAG="main"
STORAGE_SIZE=""
STORAGE_MOUNT=""
NO_GHCR=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)   DOMAIN="$2";   shift 2 ;;
    -r|--repo)     IMAGE="$2";    shift 2 ;;
    -n|--name)     APP_NAME="$2"; shift 2 ;;
    -p|--port)     PORT="$2";     shift 2 ;;
    -t|--tag)      TAG="$2";      shift 2 ;;
    --storage)
      # format: SIZE:MOUNT_PATH  e.g. 10Gi:/app/uploads
      STORAGE_SIZE="${2%%:*}"
      STORAGE_MOUNT="${2#*:}"
      shift 2
      ;;
    --no-ghcr)  NO_GHCR=true;  shift ;;
    --dry-run)  DRY_RUN=true;  shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$DOMAIN" || -z "$IMAGE" ]]; then
  echo "Error: --domain and --repo are required."
  echo "Run with --help for usage."
  exit 1
fi

# Derive app name from image basename if not provided
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(basename "$IMAGE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
fi

NAMESPACE="${APP_NAME}-production"
ARGOCD_REPO="https://github.com/prem-prakash/homeserver.git"
INFISICAL_HOST="https://infisical.internal.prakash.com.br"
INFISICAL_PROJECT="homeserver-1jj1"
# Title-case app name for Infisical path (bash 3.2 compatible)
APP_NAME_TITLE="$(tr '[:lower:]' '[:upper:]' <<< "${APP_NAME:0:1}")${APP_NAME:1}"

# Directories that will be written
MANIFESTS_DIR="${REPO_ROOT}/gitops/production/${APP_NAME}"
ARGOCD_APP="${REPO_ROOT}/gitops/applications/${APP_NAME}-production.yaml"
SECRET_STORE="${REPO_ROOT}/gitops/external-secrets/${APP_NAME}-cluster-secret-store.yaml"
KUSTOMIZATION="${REPO_ROOT}/gitops/external-secrets/kustomization.yaml"
CLOUDFLARED_SCRIPT="${REPO_ROOT}/bootstrap/k3s/cloudflared-config.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
write_file() {
  local path="$1"
  local content="$2"
  if $DRY_RUN; then
    echo "--- $path ---"
    echo "$content"
    echo ""
  else
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
    echo "  wrote: ${path#"$REPO_ROOT/"}"
  fi
}

# Detect whether the domain needs a new Cloudflare tunnel entry.
# Known wildcard zones already covered by the existing config:
known_zone() {
  local d="$1"
  [[ "$d" == *.werify.app ]] || [[ "$d" == *.prakash.com.br ]] || \
  [[ "$d" == "werify.app" ]] || [[ "$d" == "prakash.com.br" ]]
}

# ---------------------------------------------------------------------------
# 1. namespace.yaml
# ---------------------------------------------------------------------------
echo ""
echo "==> Generating GitOps manifests for '${APP_NAME}' → ${DOMAIN}"
echo ""

write_file "${MANIFESTS_DIR}/namespace.yaml" \
"apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}"

# ---------------------------------------------------------------------------
# 2. deployment.yaml + Service
# ---------------------------------------------------------------------------
VOLUME_SECTION=""
VOLUME_MOUNT_SECTION=""
if [[ -n "$STORAGE_SIZE" ]]; then
  VOLUME_MOUNT_SECTION="        volumeMounts:
        - name: data
          mountPath: ${STORAGE_MOUNT}"
  VOLUME_SECTION="      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${APP_NAME}-data"
fi

PULL_SECRETS_SECTION=""
if ! $NO_GHCR; then
  PULL_SECRETS_SECTION="      imagePullSecrets:
      - name: ghcr-credentials"
fi

write_file "${MANIFESTS_DIR}/deployment.yaml" \
"apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: ${NAMESPACE}
  name: ${APP_NAME}
  annotations:
    reloader.stakater.com/auto: \"true\"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
${PULL_SECRETS_SECTION}
      containers:
      - name: ${APP_NAME}
        image: ${IMAGE}:${TAG}
        ports:
        - containerPort: ${PORT}
          name: http
        readinessProbe:
          httpGet:
            path: /health
            port: ${PORT}
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
        livenessProbe:
          httpGet:
            path: /health
            port: ${PORT}
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 3
        envFrom:
        - secretRef:
            name: secrets
${VOLUME_MOUNT_SECTION}
        resources:
          requests:
            memory: \"128Mi\"
            cpu: \"50m\"
          limits:
            memory: \"512Mi\"
            cpu: \"500m\"
${VOLUME_SECTION}
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  ports:
  - port: ${PORT}
    targetPort: ${PORT}
    protocol: TCP
    name: http
  selector:
    app: ${APP_NAME}"

# ---------------------------------------------------------------------------
# 3. ingress.yaml
# ---------------------------------------------------------------------------
write_file "${MANIFESTS_DIR}/ingress.yaml" \
"apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${APP_NAME}
            port:
              number: ${PORT}"

# ---------------------------------------------------------------------------
# 4. external-secret.yaml
# ---------------------------------------------------------------------------
write_file "${MANIFESTS_DIR}/external-secret.yaml" \
"apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${APP_NAME}-secrets
  namespace: ${NAMESPACE}
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: ${APP_NAME}-production
    kind: ClusterSecretStore
  target:
    name: secrets
    creationPolicy: Owner
  dataFrom:
    - find:
        name:
          regexp: \".*\""

# ---------------------------------------------------------------------------
# 5. ghcr-external-secret.yaml (skip if --no-ghcr)
# ---------------------------------------------------------------------------
if ! $NO_GHCR; then
  write_file "${MANIFESTS_DIR}/ghcr-external-secret.yaml" \
"apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ghcr-credentials
  namespace: ${NAMESPACE}
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: shared
    kind: ClusterSecretStore
  target:
    name: ghcr-credentials
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |
          {
            \"auths\": {
              \"ghcr.io\": {
                \"username\": \"{{ .GHCR_USERNAME }}\",
                \"password\": \"{{ .GHCR_TOKEN }}\",
                \"auth\": \"{{ printf \\\"%s:%s\\\" .GHCR_USERNAME .GHCR_TOKEN | b64enc }}\"
              }
            }
          }
  data:
    - secretKey: GHCR_USERNAME
      remoteRef:
        key: GHCR_USERNAME
    - secretKey: GHCR_TOKEN
      remoteRef:
        key: GHCR_TOKEN"
fi

# ---------------------------------------------------------------------------
# 6. pvc.yaml (only if --storage provided)
# ---------------------------------------------------------------------------
if [[ -n "$STORAGE_SIZE" ]]; then
  write_file "${MANIFESTS_DIR}/pvc.yaml" \
"apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP_NAME}-data
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path-static
  volumeName: ${APP_NAME}-production-data
  resources:
    requests:
      storage: ${STORAGE_SIZE}"

  write_file "${REPO_ROOT}/gitops/storageclass/${APP_NAME}-production-data-pv.yaml" \
"apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${APP_NAME}-production-data
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path-static
  local:
    path: /mnt/k8s-persistent/pvs/${APP_NAME}-production-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k3s-apps"
fi

# ---------------------------------------------------------------------------
# 7. kustomization.yaml
# ---------------------------------------------------------------------------
KUSTOMIZE_RESOURCES="  - namespace.yaml
  - external-secret.yaml
  - deployment.yaml
  - ingress.yaml"
if ! $NO_GHCR; then
  KUSTOMIZE_RESOURCES="${KUSTOMIZE_RESOURCES}
  - ghcr-external-secret.yaml"
fi
if [[ -n "$STORAGE_SIZE" ]]; then
  KUSTOMIZE_RESOURCES="${KUSTOMIZE_RESOURCES}
  - pvc.yaml"
fi

write_file "${MANIFESTS_DIR}/kustomization.yaml" \
"apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
${KUSTOMIZE_RESOURCES}"

# ---------------------------------------------------------------------------
# 8. Argo CD Application
# ---------------------------------------------------------------------------
write_file "${ARGOCD_APP}" \
"apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}-production
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${ARGOCD_REPO}
    targetRevision: main
    path: gitops/production/${APP_NAME}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true"

# ---------------------------------------------------------------------------
# 9. ClusterSecretStore for the new app
# ---------------------------------------------------------------------------
write_file "${SECRET_STORE}" \
"# =============================================================================
# ClusterSecretStores for ${APP_NAME}
# Pulls secrets from Infisical project \"homeserver\", path \"/${APP_NAME_TITLE}/\"
# Add your secrets in Infisical under: prod → /${APP_NAME_TITLE}/
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${APP_NAME}-production
spec:
  provider:
    infisical:
      hostAPI: ${INFISICAL_HOST}
      auth:
        universalAuthCredentials:
          clientId:
            name: infisical-credentials
            namespace: external-secrets
            key: clientId
          clientSecret:
            name: infisical-credentials
            namespace: external-secrets
            key: clientSecret
      secretsScope:
        projectSlug: ${INFISICAL_PROJECT}
        environmentSlug: prod
        secretsPath: \"/${APP_NAME_TITLE}/\""

# ---------------------------------------------------------------------------
# 10. Patch gitops/external-secrets/kustomization.yaml
# ---------------------------------------------------------------------------
NEW_RESOURCE="  - ${APP_NAME}-cluster-secret-store.yaml"
if $DRY_RUN; then
  echo "--- patch: gitops/external-secrets/kustomization.yaml ---"
  echo "  append: ${NEW_RESOURCE}"
  echo ""
else
  if grep -qF "${APP_NAME}-cluster-secret-store.yaml" "${KUSTOMIZATION}"; then
    echo "  skipped: ${APP_NAME}-cluster-secret-store.yaml already in kustomization"
  else
    echo "${NEW_RESOURCE}" >> "${KUSTOMIZATION}"
    echo "  patched: gitops/external-secrets/kustomization.yaml"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Cloudflare tunnel config (only for new/unknown domains)
# ---------------------------------------------------------------------------
if known_zone "$DOMAIN"; then
  echo ""
  echo "  domain '${DOMAIN}' is already covered by an existing wildcard tunnel rule — no cloudflared changes needed."
else
  echo ""
  echo "==> '${DOMAIN}' is a new domain — patching cloudflared-config.sh ..."

  # Insert two new ingress entries before the catch-all `- service: http_status:404` line
  NEW_INGRESS="  - hostname: \"*.${DOMAIN}\"
    service: http://\${INGRESS_NGINX_IP}:\${INGRESS_NGINX_PORT}
  - hostname: \"${DOMAIN}\"
    service: http://\${INGRESS_NGINX_IP}:\${INGRESS_NGINX_PORT}"

  NEW_DNS_ROUTES="  create_dns_route \"\${TUNNEL_NAME}\" \"${DOMAIN}\" \"\${TUNNEL_ID}\"
  create_dns_route \"\${TUNNEL_NAME}\" \"*.${DOMAIN}\" \"\${TUNNEL_ID}\""

  if $DRY_RUN; then
    echo "--- patch: bootstrap/k3s/cloudflared-config.sh ---"
    echo "  add to ingress block:"
    echo "$NEW_INGRESS"
    echo ""
    echo "  add to DNS routes block:"
    echo "$NEW_DNS_ROUTES"
    echo ""
  else
    # Patch ingress block: insert before the catch-all line
    INGRESS_ANCHOR="  - service: http_status:404"
    if grep -qF "$INGRESS_ANCHOR" "${CLOUDFLARED_SCRIPT}"; then
      # Use python for reliable multi-line sed (avoids BSD/GNU differences)
      python3 - "${CLOUDFLARED_SCRIPT}" "${INGRESS_ANCHOR}" "${NEW_INGRESS}" <<'PYEOF'
import sys
path, anchor, insert = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read()
lines = lines.replace(anchor, insert + "\n" + anchor, 1)
open(path, "w").write(lines)
PYEOF
      echo "  patched: cloudflared ingress block in cloudflared-config.sh"
    else
      echo "  WARNING: could not find ingress catch-all line in cloudflared-config.sh — add manually:"
      echo "    ${NEW_INGRESS}"
    fi

    # Patch DNS routes block: find the last create_dns_route line and append after it
    DNS_ANCHOR_PATTERN="create_dns_route"
    if grep -qF "$DNS_ANCHOR_PATTERN" "${CLOUDFLARED_SCRIPT}"; then
      python3 - "${CLOUDFLARED_SCRIPT}" "${NEW_DNS_ROUTES}" <<'PYEOF'
import sys, re
path, insert = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
last_idx = -1
for i, line in enumerate(lines):
    if "create_dns_route" in line:
        last_idx = i
if last_idx >= 0:
    lines.insert(last_idx + 1, insert + "\n")
open(path, "w").writelines(lines)
PYEOF
      echo "  patched: DNS routes block in cloudflared-config.sh"
    else
      echo "  WARNING: could not find create_dns_route calls in cloudflared-config.sh — add manually:"
      echo "    ${NEW_DNS_ROUTES}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " App '${APP_NAME}' scaffolded successfully!"
echo "================================================================"
echo ""
echo " Files written:"
echo "   gitops/production/${APP_NAME}/"
echo "   gitops/applications/${APP_NAME}-production.yaml"
echo "   gitops/external-secrets/${APP_NAME}-cluster-secret-store.yaml"
if [[ -n "$STORAGE_SIZE" ]]; then
  echo "   gitops/storageclass/${APP_NAME}-production-data-pv.yaml"
fi
echo ""
echo " Next steps:"
echo ""
echo " 1. Add secrets to Infisical"
echo "    Project : ${INFISICAL_PROJECT}"
echo "    Env     : prod"
echo "    Path    : /${APP_NAME_TITLE}/"
echo ""
if [[ -n "$STORAGE_SIZE" ]]; then
  echo " 2. Create the storage directory on the k3s VM:"
  echo "    ssh deployer@192.168.20.11 \\"
  echo "      'sudo mkdir -p /mnt/k8s-persistent/pvs/${APP_NAME}-production-data'"
  echo ""
  echo " 3. Commit and push — Argo CD will sync automatically."
else
  echo " 2. Commit and push — Argo CD will sync automatically."
fi
echo ""
if ! known_zone "$DOMAIN"; then
  echo " !! NEW DOMAIN: after pushing, run the updated cloudflared-config.sh"
  echo "    locally to register the tunnel ingress and create DNS records:"
  echo ""
  echo "    CF_API_TOKEN=<your-token> ./bootstrap/k3s/cloudflared-config.sh"
  echo ""
fi
echo ""
echo " Health probe is set to GET /health:${PORT} — adjust ingress.yaml"
echo " or deployment.yaml if your app uses a different path."
echo ""
