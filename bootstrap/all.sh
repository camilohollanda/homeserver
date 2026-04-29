#!/usr/bin/env bash
# Provisions all VMs in dependency order from the local machine.
# Run this after `terraform apply` to fully configure the infrastructure.
#
# Usage:
#   ./bootstrap/all.sh
#
# All configuration is read from environment variables. Set them via mise,
# .env, or by exporting in your shell before running this script.
#
# Required env vars — see each setup.sh for the full list per VM:
#   CF_API_TOKEN, LETSENCRYPT_EMAIL
#   PG_DOMAIN
#   INFISICAL_DOMAIN, INFISICAL_ENCRYPTION_KEY, INFISICAL_AUTH_SECRET, INFISICAL_DB_URI
#   DOMAIN_JELLYFIN, DOMAIN_QBITTORRENT, DOMAIN_RADARR, DOMAIN_SONARR, DOMAIN_PROWLARR, DOMAIN_BAZARR
#   AI_DOMAIN, GITHUB_OWNER, GHCR_USERNAME, GHCR_TOKEN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  Full Infrastructure Bootstrap"
echo "=============================================="
echo ""

# 1. Postgres first — Infisical depends on it
echo "--- [1/4] PostgreSQL ---"
bash "${SCRIPT_DIR}/postgres/setup.sh"

# 2. Infisical — depends on Postgres
echo ""
echo "--- [2/4] Infisical ---"
bash "${SCRIPT_DIR}/infisical/setup.sh"

# 3. K3s — independent, but needs Infisical running to sync secrets
echo ""
echo "--- [3/4] K3s cluster ---"
bash "${SCRIPT_DIR}/k3s/setup.sh"

# 4. AI and Media — fully independent, run in parallel background
echo ""
echo "--- [4/4] AI + Media (parallel) ---"
bash "${SCRIPT_DIR}/ai/setup.sh" &
AI_PID=$!
bash "${SCRIPT_DIR}/media/setup.sh" &
MEDIA_PID=$!

wait $AI_PID    && echo "✓ AI setup done"    || echo "✗ AI setup failed"
wait $MEDIA_PID && echo "✓ Media setup done" || echo "✗ Media setup failed"

echo ""
echo "=============================================="
echo "  All VMs provisioned!"
echo "=============================================="
echo ""
echo "Manual post-steps for k3s (see k3s/setup.sh output for commands):"
echo "  1. Create infisical-credentials Kubernetes secret"
echo "  2. Run argocd-github-setup.sh (interactive)"
echo "  3. Set up persistent storage if needed"
echo ""
