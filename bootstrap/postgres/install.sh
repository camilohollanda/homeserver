#!/usr/bin/env bash
# Runs on the postgres VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.23 ./install.sh
#
# TLS: this cluster is LAN-only and every client connects by IP without an
# `sslmode`, so libpq lands on `prefer` and never verifies a certificate. The
# script therefore keeps Debian's stock snakeoil cert and does NOT provision
# Let's Encrypt. That is not a downgrade — until 2026-08-06 the VM 113 ran the
# full certbot dance and *still* served snakeoil, because the sed that was meant
# to point postgresql.conf at the LE files only fired on a commented default
# that Debian ships uncommented. See bootstrap/postgres/README.md.
#
# Required env vars:
#   PG_VERSION         - PostgreSQL major version (default: 18)
#   ALLOWED_NETWORK    - CIDR allowed to connect (default: 192.168.20.0/24)
#   PG_DATA_ROOT       - parent of the data directory (default: /data/postgresql)
#   RESERVED_ROLES     - roles granted pg_use_reserved_connections (default: infisical)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      PG_VERSION        "${PG_VERSION:-18}" \
      ALLOWED_NETWORK   "${ALLOWED_NETWORK:-192.168.20.0/24}" \
      PG_DATA_ROOT      "${PG_DATA_ROOT:-/data/postgresql}" \
      RESERVED_ROLES    "${RESERVED_ROLES:-infisical}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

PG_VERSION="${PG_VERSION:-18}"
ALLOWED_NETWORK="${ALLOWED_NETWORK:-192.168.20.0/24}"
PG_DATA_ROOT="${PG_DATA_ROOT:-/data/postgresql}"
RESERVED_ROLES="${RESERVED_ROLES:-infisical}"
PG_DATA="${PG_DATA_ROOT}/${PG_VERSION}_main"

echo "==> Installing base dependencies..."
apt-get update -qq
apt-get install -y -qq wget ca-certificates gnupg lsb-release

# ---------------------------------------------------------------------------
# PostgreSQL installation
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing PostgreSQL ${PG_VERSION}..."

# PG 18 is not in Debian 13's own archive — pgdg is required.
if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  install -d -m 0755 /etc/apt/keyrings
  wget -q -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  chmod 644 /etc/apt/keyrings/postgresql.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
fi

# Version-specific guard. The previous check was `command -v psql`, which on any
# host that already had *some* PostgreSQL would skip the install entirely and
# still report success — exactly the wrong behaviour on an upgrade host.
if ! dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
  apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
else
  echo "  postgresql-${PG_VERSION} already installed — skipping."
fi

# ---------------------------------------------------------------------------
# Cluster on the data disk
# ---------------------------------------------------------------------------
# Debian auto-creates <ver>/main under /var/lib/postgresql on install. The data
# disk is a separate volume so the databases survive VM recreation, so the
# cluster is dropped and recreated in place. pg_dropcluster is destructive —
# hence the two guards below, which must BOTH hold.
echo ""
echo "==> Ensuring cluster ${PG_VERSION}/main lives on ${PG_DATA}..."

if [[ -d "$PG_DATA" ]]; then
  echo "  ${PG_DATA} already exists — skipping relocation."
else
  mountpoint -q /data || {
    echo "Error: /data is not a mountpoint. Attach and mount the data disk first" >&2
    echo "       (see bootstrap/postgres/README.md)." >&2
    exit 1
  }

  user_dbs="$(sudo -u postgres psql -tAc \
    "select count(*) from pg_database where datname not in ('postgres','template0','template1')" \
    2>/dev/null || echo unknown)"
  if [[ "$user_dbs" != "0" ]]; then
    echo "Error: cluster ${PG_VERSION}/main reports '${user_dbs}' user databases." >&2
    echo "       Refusing to run pg_dropcluster. Relocate by hand or verify the cluster." >&2
    exit 1
  fi

  install -d -m 0755 -o postgres -g postgres "$PG_DATA_ROOT"
  pg_dropcluster --stop "${PG_VERSION}" main
  # No --no-data-checksums: PG 18's initdb enables checksums by default and this
  # is a brand-new cluster, so there is no pg_upgrade compatibility constraint to
  # satisfy. The old VM 113 cluster has them off; this one gets them on.
  pg_createcluster "${PG_VERSION}" main -d "$PG_DATA"
  echo "  ✓ cluster recreated at ${PG_DATA} (data checksums on)"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
echo ""
echo "==> Configuring..."

PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

grep -q "^#listen_addresses" "$PG_CONF" \
  && sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF" || true

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
# members of the predefined pg_use_reserved_connections role can draw from these
# slots after the apps have filled the rest, so an app pool can never starve
# secret reads/writes. Postmaster context -> needs a restart (done below).
grep -q "^reserved_connections = 5" "$PG_CONF" \
  || sed -i -E "s/^[# ]*reserved_connections = .*/reserved_connections = 5/" "$PG_CONF"

PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q "$ALLOWED_NETWORK" "$PG_HBA"; then
  cat >> "$PG_HBA" <<HBA

# Allow connections from the local network
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
echo "  Data dir   : ${PG_DATA}"
echo "  Allowed    : ${ALLOWED_NETWORK}"
