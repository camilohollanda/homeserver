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
echo "==> Writing configuration..."

PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

# Idempotent setter. Rewrites the key whether it is the commented default, an
# already-set value, or absent from the file entirely (some keys don't ship in
# the stock config). Appending is safe: within postgresql.conf the last
# occurrence wins.
#
# The `#?` sits between two whitespace classes rather than at the line start, so
# `reserved_connections` can never match `superuser_reserved_connections` — the
# literal key has to follow the optional comment marker directly.
set_conf() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$PG_CONF"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$PG_CONF"
  else
    printf '%s = %s\n' "$key" "$val" >> "$PG_CONF"
  fi
}

# Backup before touching anything, so a failed start has an obvious way back.
cp -a "$PG_CONF" "${PG_CONF}.bak.$(date +%Y%m%d%H%M%S)"

set_conf listen_addresses "'*'"

# Shared instance: werify (prod+staging), iddh (prod+staging), infisical, bugsink
# and umami each hold their own pool, and a rolling deploy briefly doubles an
# app's pool (Deployment maxSurge). The stock 100 was exhausted in practice
# (FATAL 53300 too_many_connections). Measured baseline on the VM 113 on
# 2026-08-06 was 122 held connections at rest, 116 of them idle.
set_conf max_connections 200

# Hold back slots that only members of pg_use_reserved_connections may use once
# the apps have filled the rest, so a runaway app pool can never lock Infisical
# out of its own DB — which would otherwise block *changing* the secret that
# caused the runaway. The grant is applied further down. Apps top out at
# max_connections - 3 (superuser) - 5 = 192.
set_conf reserved_connections 5

# 7.7 GB VM, 4 vCPU, SSD, ~925 MB of data. shared_buffers holds the whole
# dataset with room to grow. work_mem is deliberately NOT raised: 200 potential
# connections x 4 MB is already 800 MB of worst case.
set_conf shared_buffers "2GB"
set_conf effective_cache_size "5GB"
set_conf maintenance_work_mem "256MB"

# The default of 4 assumes spinning rust and makes the planner underestimate
# index scans on SSD. This is the single change here most likely to show up in
# query plans.
set_conf random_page_cost "1.1"

# --- assertion gate -------------------------------------------------------
# A sed that matches nothing is silent, and the failure mode is shipping the
# default (max_connections back to 100) into a restart. Verify every key landed
# BEFORE restarting.
echo ""
echo "==> Verifying settings landed in ${PG_CONF}..."
assert_conf() {
  local key="$1" want="$2" got
  got="$(grep -E "^${key}[[:space:]]*=" "$PG_CONF" | tail -1 \
         | sed -E "s|^${key}[[:space:]]*=[[:space:]]*||; s|[[:space:]]*#.*$||; s|[[:space:]]*$||")"
  if [[ "$got" != "$want" ]]; then
    echo "Error: ${key} reads '${got}', expected '${want}' — aborting before restart." >&2
    exit 1
  fi
  printf '  ✓ %-22s %s\n' "$key" "$got"
}

assert_conf listen_addresses "'*'"
assert_conf max_connections "200"
assert_conf reserved_connections "5"
assert_conf shared_buffers "2GB"
assert_conf effective_cache_size "5GB"
assert_conf maintenance_work_mem "256MB"
assert_conf random_page_cost "1.1"

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
echo "    NOTE: this restarts the cluster and drops every open connection."
systemctl enable postgresql
if systemctl is-active --quiet "postgresql@${PG_VERSION}-main"; then
  systemctl restart "postgresql@${PG_VERSION}-main"
else
  systemctl start "postgresql@${PG_VERSION}-main"
fi

echo -n "  Waiting for postgres to accept queries"
for _ in $(seq 1 30); do
  if sudo -u postgres pg_isready -q; then echo " ✓"; break; fi
  echo -n "."; sleep 1
done
sudo -u postgres pg_isready -q || { echo "Error: cluster did not come up." >&2; exit 1; }

# Consolidate the source of truth. On the VM 113 max_connections lived ONLY in
# postgresql.auto.conf (set by a manual ALTER SYSTEM), i.e. a critical value that
# existed on the box and nowhere in git. Dropping the override makes
# postgresql.conf — which this script owns — authoritative. No-op on a fresh
# cluster.
sudo -u postgres psql -qc "ALTER SYSTEM RESET max_connections;"
sudo -u postgres psql -qc "SELECT pg_reload_conf();" >/dev/null

# Keep app roles out of the system databases. This is cluster policy, not
# per-app provisioning, because it can only be expressed by revoking from
# PUBLIC: CONNECT on a database with a NULL datacl is inherited from PUBLIC's
# default grant, and PostgreSQL has no negative grants, so taking it away from
# one role takes away nothing. pg-provision.sh used to try exactly that
# (`REVOKE CONNECT ON DATABASE postgres FROM <role>`) and had no effect on
# either cluster for as long as it existed.
#
# Safe because superusers bypass ACL checks entirely, so postgres, pg_dumpall
# and wal-g are unaffected; and no login role has CREATEDB, so nothing needs to
# read template1 in order to create a database from it.
sudo -u postgres psql -qc "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;"
sudo -u postgres psql -qc "REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;"
echo "  ✓ PUBLIC cannot connect to the postgres/template1 databases"

# Heal the reserved-connections grant. The same GRANT lives in
# bootstrap/infisical/db-setup.sh for fresh provisioning, but that script needs
# DB_PASSWORD and re-running it with the wrong one would break Infisical's
# login. This path is cluster-level and needs no password. It exists because
# db-setup.sh was never re-run after the GRANT was added, so the live cluster
# went from ~jan/2026 to 2026-08-06 with the protection inert on both ends.
for role in $RESERVED_ROLES; do
  if sudo -u postgres psql -tAc "select 1 from pg_roles where rolname='${role}'" | grep -q 1; then
    sudo -u postgres psql -qc "GRANT pg_use_reserved_connections TO ${role};"
    echo "  ✓ granted pg_use_reserved_connections to '${role}'"
  else
    echo "  role '${role}' not present yet — db-setup.sh will apply the grant"
  fi
done

echo ""
echo "✓ PostgreSQL ${PG_VERSION} installed and running."
echo "  Data dir   : ${PG_DATA}"
echo "  Allowed    : ${ALLOWED_NETWORK}"
echo "  Verify     : sudo -u postgres psql -c 'SHOW shared_buffers; SHOW reserved_connections;'"
