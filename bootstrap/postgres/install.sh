#!/usr/bin/env bash
# Runs on the postgres VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.21 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN       - Cloudflare API token (Zone.DNS Edit)
#   PG_DOMAIN          - FQDN for the postgres VM (e.g. pg.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL  - Email for Let's Encrypt
#   PG_VERSION         - PostgreSQL major version (default: 17)
#   ALLOWED_NETWORK    - CIDR allowed to connect (default: 192.168.20.0/24)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN      "${CF_API_TOKEN:-}" \
      PG_DOMAIN         "${PG_DOMAIN:-}" \
      LETSENCRYPT_EMAIL "${LETSENCRYPT_EMAIL:-}" \
      PG_VERSION        "${PG_VERSION:-17}" \
      ALLOWED_NETWORK   "${ALLOWED_NETWORK:-192.168.20.0/24}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

PG_VERSION="${PG_VERSION:-17}"
ALLOWED_NETWORK="${ALLOWED_NETWORK:-192.168.20.0/24}"

echo "==> Installing base dependencies..."
apt-get update -qq
apt-get install -y -qq wget ca-certificates gnupg lsb-release certbot python3-certbot-dns-cloudflare

# ---------------------------------------------------------------------------
# Let's Encrypt certificate
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${PG_DOMAIN}..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

cat > /etc/letsencrypt/renewal-hooks/deploy/postgres-ssl.sh <<'HOOK'
#!/bin/bash
DOMAIN="__PG_DOMAIN__"
PG_VERSION="__PG_VERSION__"
SSL_DIR="/etc/postgresql/$PG_VERSION/main/ssl"
mkdir -p "$SSL_DIR"
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/server.crt"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"   "$SSL_DIR/server.key"
chown postgres:postgres "$SSL_DIR"/*
chmod 600 "$SSL_DIR/server.key"
chmod 644 "$SSL_DIR/server.crt"
systemctl reload postgresql
HOOK
# Substitute real values into the hook (avoids nested variable expansion)
sed -i "s/__PG_DOMAIN__/${PG_DOMAIN}/g; s/__PG_VERSION__/${PG_VERSION}/g" \
  /etc/letsencrypt/renewal-hooks/deploy/postgres-ssl.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/postgres-ssl.sh

if [ ! -d "/etc/letsencrypt/live/${PG_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${PG_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# PostgreSQL installation
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing PostgreSQL ${PG_VERSION}..."

if ! command -v psql &>/dev/null; then
  wget -q -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  chmod 644 /etc/apt/keyrings/postgresql.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | tee /etc/apt/sources.list.d/pgdg.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
else
  echo "  PostgreSQL already installed — skipping."
fi

# ---------------------------------------------------------------------------
# SSL configuration
# ---------------------------------------------------------------------------
echo ""
echo "==> Configuring SSL..."

SSL_DIR="/etc/postgresql/${PG_VERSION}/main/ssl"
mkdir -p "$SSL_DIR"
cp "/etc/letsencrypt/live/${PG_DOMAIN}/fullchain.pem" "$SSL_DIR/server.crt"
cp "/etc/letsencrypt/live/${PG_DOMAIN}/privkey.pem"   "$SSL_DIR/server.key"
chown -R postgres:postgres "$SSL_DIR"
chmod 600 "$SSL_DIR/server.key"
chmod 644 "$SSL_DIR/server.crt"

PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
# Idempotent: only sed if the commented default is still present
grep -q "^#listen_addresses" "$PG_CONF" \
  && sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF" || true
grep -q "^#ssl = off" "$PG_CONF" \
  && sed -i "s/#ssl = off/ssl = on/" "$PG_CONF" || true
grep -q "^#ssl_cert_file" "$PG_CONF" \
  && sed -i "s|#ssl_cert_file = 'server.crt'|ssl_cert_file = '${SSL_DIR}/server.crt'|" "$PG_CONF" || true
grep -q "^#ssl_key_file" "$PG_CONF" \
  && sed -i "s|#ssl_key_file = 'server.key'|ssl_key_file = '${SSL_DIR}/server.key'|" "$PG_CONF" || true

# Raise the connection ceiling. This is a *shared* instance: werify (prod+staging),
# iddh (prod+staging), infisical and others each hold their own pool, and a rolling
# deploy briefly doubles an app's pool (Deployment maxSurge). The stock 100 was
# exhausted in practice (clients got FATAL 53300 too_many_connections). 200 gives
# headroom and fits the VM's RAM (~10 MB/backend << 7.7 GB). Requires a restart
# (done below). Idempotent: rewrites whether the line is the commented default or
# a previously-set value, and is a no-op once it already reads 200.
grep -q "^max_connections = 200" "$PG_CONF" \
  || sed -i -E "s/^[# ]*max_connections = .*/max_connections = 200/" "$PG_CONF"

# Reserve a few slots so Infisical keeps priority over the apps. Roles that are
# members of the predefined pg_use_reserved_connections role (the grant lives in
# bootstrap/infisical/db-setup.sh) can draw from these slots after the apps have
# filled the rest, so an app pool can never starve secret reads/writes. Postmaster
# context -> needs a restart (done below). Idempotent.
grep -q "^reserved_connections = 5" "$PG_CONF" \
  || sed -i -E "s/^[# ]*reserved_connections = .*/reserved_connections = 5/" "$PG_CONF"

PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q "$ALLOWED_NETWORK" "$PG_HBA"; then
  cat >> "$PG_HBA" <<HBA

# Allow SSL connections from local network
hostssl all all ${ALLOWED_NETWORK} scram-sha-256
host    all all ${ALLOWED_NETWORK} scram-sha-256
HBA
fi

# ---------------------------------------------------------------------------
# Start / restart
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting PostgreSQL..."
systemctl enable postgresql
if systemctl is-active --quiet postgresql; then
  systemctl restart postgresql
else
  systemctl start postgresql
fi

echo ""
echo "✓ PostgreSQL ${PG_VERSION} installed and running."
echo "  SSL domain : ${PG_DOMAIN}"
echo "  Allowed    : ${ALLOWED_NETWORK}"
