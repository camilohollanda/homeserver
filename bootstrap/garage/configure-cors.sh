#!/usr/bin/env bash
# Update CORS on an existing bucket, without creating keys or changing grants.
# Runs on the services VM as root; remote execution forwards only these inputs.
# Usage: REMOTE_HOST=deployer@192.168.20.22 CORS_BUCKET=miora-staging \
#   CORS_ORIGINS=https://staging.miora.now bash bootstrap/garage/configure-cors.sh
# CORS_DRY_RUN=1 prints the proposed rules without writing them.
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CORS_BUCKET "${CORS_BUCKET:-}" \
      CORS_ORIGINS "${CORS_ORIGINS:-}" \
      CORS_DRY_RUN "${CORS_DRY_RUN:-0}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 || ! -f /opt/services/docker-compose.yml || ! -f /opt/garage/.env ]]; then
  echo "Error: run as root on the services VM after installing services + Garage." >&2
  exit 1
fi
export CORS_BUCKET="${CORS_BUCKET:?existing bucket global alias required}"
export CORS_ORIGINS="${CORS_ORIGINS:?comma-separated exact web origins required}"

python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request

bucket = os.environ["CORS_BUCKET"]
origins = list(dict.fromkeys(x.strip() for x in os.environ["CORS_ORIGINS"].split(",")))
for origin in origins:
    url = urllib.parse.urlsplit(origin)
    if (url.scheme not in ("https", "http") or not url.hostname
            or url.username or url.password or url.path or url.query or url.fragment
            or "*" in origin or any(c.isspace() for c in origin)):
        raise SystemExit(f"Error: expected an exact origin (scheme + host + optional port): {origin!r}")

token = next(line.split("=", 1)[1].strip().strip('"')
             for line in Path("/opt/garage/.env").read_text().splitlines()
             if line.startswith("GARAGE_ADMIN_TOKEN="))

def admin(operation, params, body=None):
    request = urllib.request.Request(
        "http://127.0.0.1:3903/v2/" + operation + "?" + urllib.parse.urlencode(params),
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST" if body is not None else "GET",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

current = admin("GetBucketInfo", {"globalAlias": bucket})
# Garage joins all AllowedOrigin values in a rule into a single response
# header. One rule per exact origin produces browser-valid ACAO headers.
rules = [{
    "AllowedOrigin": [origin],
    "AllowedMethod": ["GET", "PUT", "POST", "HEAD", "DELETE"],
    "AllowedHeader": ["*"],
    "ExposeHeader": ["ETag"],
    "MaxAgeSeconds": 3000,
} for origin in origins]

if current.get("corsRules") == rules:
    print(f"CORS already current: {bucket}")
elif os.environ.get("CORS_DRY_RUN") == "1":
    print(json.dumps({"bucket": bucket, "corsRules": rules}, indent=2))
else:
    # Keep the previous CORS policy for rollback; no keys/tokens in this file.
    backup_dir = Path("/opt/garage/cors-backups")
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = backup_dir / f"{current['id']}-{stamp}.json"
    with backup.open("x") as output:
        os.fchmod(output.fileno(), 0o600)
        json.dump({"corsRules": current.get("corsRules") or []}, output, indent=2)
    admin("UpdateBucket", {"id": current["id"]}, {"corsRules": rules})
    actual = admin("GetBucketInfo", {"id": current["id"]})
    if actual.get("corsRules") != rules:
        raise SystemExit("Error: CORS read-back does not match the requested policy")
    print(f"CORS updated and verified: {bucket}; previous policy: {backup}")
PY
