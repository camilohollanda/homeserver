#!/usr/bin/env bash
# Provisions a per-app bucket on Garage: bucket + access key + CORS rule.
# Runs locally; SSHes into the services VM for all Garage operations.
#
# NOTE: the CORS step only matters if Garage is reachable from a browser —
# i.e. the S3 endpoint is exposed to the public internet (e.g. via a
# Cloudflare Tunnel route). In the current setup Garage is LAN-only behind
# the shared services nginx, so browsers never hit it directly and CORS is
# a no-op. The bucket + key + grant steps still apply for server-side use.
#
# Usage:
#   ./configure-app.sh <bucket> <endpoint-host> "<origin1,origin2,...>"
#
# Example:
#   ./configure-app.sh werify storage.werify.app \
#     "https://werify.app,https://www.werify.app,https://staging.werify.app"
#
# Optional env vars:
#   SERVICES_SSH   - default: deployer@192.168.20.22
#   GARAGE_S3_PORT - default: 3900 (Garage's S3 endpoint, reached via 127.0.0.1
#                    on the services VM from inside the aws-cli container)
set -euo pipefail

BUCKET="${1:?bucket name required (e.g. werify, werify-staging, iddh-members)}"
ENDPOINT_HOST="${2:?endpoint hostname required (e.g. storage.werify.app)}"
ORIGINS_CSV="${3:?origins CSV required (e.g. https://werify.app,https://staging.werify.app)}"

SERVICES_SSH="${SERVICES_SSH:-deployer@192.168.20.22}"
GARAGE_S3_PORT="${GARAGE_S3_PORT:-3900}"

remote() { ssh "$SERVICES_SSH" "$@"; }

# ---------------------------------------------------------------------------
# 1. Bucket
# ---------------------------------------------------------------------------
echo "==> Ensuring bucket '${BUCKET}'..."
if remote "sudo docker exec garage /garage bucket info ${BUCKET}" &>/dev/null; then
  echo "  Bucket exists — keeping it."
else
  remote "sudo docker exec garage /garage bucket create ${BUCKET}"
fi

# ---------------------------------------------------------------------------
# 2. Access key
# ---------------------------------------------------------------------------
KEY_NAME="${BUCKET}-key"
echo ""
echo "==> Ensuring key '${KEY_NAME}'..."
if remote "sudo docker exec garage /garage key info ${KEY_NAME}" &>/dev/null; then
  echo "  Key exists — fetching credentials."
  KEY_INFO="$(remote "sudo docker exec garage /garage key info --show-secret ${KEY_NAME}")"
else
  KEY_INFO="$(remote "sudo docker exec garage /garage key create ${KEY_NAME}")"
fi

ACCESS_KEY_ID="$(echo "$KEY_INFO" | awk -F': *' 'tolower($1) ~ /^key id/ {print $2; exit}' | tr -d '[:space:]')"
SECRET_ACCESS_KEY="$(echo "$KEY_INFO" | awk -F': *' 'tolower($1) ~ /secret key/ {print $2; exit}' | tr -d '[:space:]')"

if [[ -z "$ACCESS_KEY_ID" || -z "$SECRET_ACCESS_KEY" ]]; then
  echo "Error: could not parse access key ID / secret from garage CLI output." >&2
  echo "  Raw output was:" >&2
  echo "$KEY_INFO" | sed 's/^/    /' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Grant bucket -> key
# ---------------------------------------------------------------------------
echo ""
echo "==> Granting read/write/owner on ${BUCKET} to ${KEY_NAME}..."
remote "sudo docker exec garage /garage bucket allow --read --write --owner ${BUCKET} --key ${KEY_NAME}"

# ---------------------------------------------------------------------------
# 4. CORS rule via S3 PutBucketCors (signed call, run from a throwaway
#    aws-cli container on the services VM to keep dependencies off the host)
# ---------------------------------------------------------------------------
echo ""
echo "==> Applying CORS rule (origins: ${ORIGINS_CSV})..."

IFS=',' read -ra ORIGINS <<< "$ORIGINS_CSV"

# One CORSRule per origin: S3 (and Garage) only echo the *first* AllowedOrigin
# of a matched rule back in Access-Control-Allow-Origin, so bundling multiple
# origins into a single rule silently breaks all origins after the first.
RULES_JSON=""
for origin in "${ORIGINS[@]}"; do
  RULES_JSON+=$(cat <<JSON
    {
      "AllowedOrigins": ["${origin}"],
      "AllowedMethods": ["GET", "PUT", "POST", "HEAD", "DELETE"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    },
JSON
)
done
RULES_JSON="${RULES_JSON%,}"

CORS_JSON=$(cat <<JSON
{
  "CORSRules": [
${RULES_JSON}
  ]
}
JSON
)

# Note: --network host so the container reaches Garage on 127.0.0.1:3900.
remote "sudo docker run --rm --network host \
  -e AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID} \
  -e AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY} \
  -e AWS_DEFAULT_REGION=garage \
  amazon/aws-cli:latest \
  --endpoint-url http://127.0.0.1:${GARAGE_S3_PORT} \
  s3api put-bucket-cors \
  --bucket ${BUCKET} \
  --cors-configuration '${CORS_JSON}'"

echo ""
echo "=============================================="
echo "  Configured: ${BUCKET}"
echo "=============================================="
echo ""
echo "  Endpoint:   https://${ENDPOINT_HOST}"
echo "  Bucket:     ${BUCKET}"
echo "  Region:     garage"
echo "  Origins:    ${ORIGINS[*]}"
echo ""
echo "  Store in Infisical (project homeserver, path /Garage/${BUCKET}/):"
echo "    S3_ENDPOINT=https://${ENDPOINT_HOST}"
echo "    S3_REGION=garage"
echo "    S3_BUCKET=${BUCKET}"
echo "    S3_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
echo "    S3_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
echo ""
echo "  SDK note: use path-style addressing"
echo "    AWS SDK v3 (JS):  forcePathStyle: true"
echo "    boto3:            already path-style when endpoint_url is set"
echo ""
