#!/usr/bin/env bash
# Runs on the database VM, as root.
# Remote: REMOTE_HOST=deployer@192.168.20.23 ./install.sh
#
# Installs prometheus-postgres-exporter from Debian and gives it a read-only
# role. The role is granted pg_monitor, which is the built-in role for exactly
# this: it can read the statistics views and nothing else. No superuser.
#
# Required env vars:
#   PG_EXPORTER_PASSWORD - password for the postgres_exporter role
#
# Optional env vars:
#   PG_EXPORTER_PORT     - listen port (default: 9187)
#   PG_EXPORTER_ROLE     - role name (default: postgres_exporter)
#   PG_EXPORTER_DB       - database to connect to (default: postgres)
#   PG_EXPORTER_CONNLIMIT- role connection limit (default: 5)
#   LAN_PROBE_ADDR       - address used to derive the LAN IP (default: 192.168.20.1)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      PG_EXPORTER_PASSWORD  "${PG_EXPORTER_PASSWORD:-}" \
      PG_EXPORTER_PORT      "${PG_EXPORTER_PORT:-}" \
      PG_EXPORTER_ROLE      "${PG_EXPORTER_ROLE:-}" \
      PG_EXPORTER_DB        "${PG_EXPORTER_DB:-}" \
      PG_EXPORTER_CONNLIMIT "${PG_EXPORTER_CONNLIMIT:-}" \
      LAN_PROBE_ADDR        "${LAN_PROBE_ADDR:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" sudo bash -s
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution" >&2
  exit 1
fi

PG_EXPORTER_PORT="${PG_EXPORTER_PORT:-9187}"
PG_EXPORTER_ROLE="${PG_EXPORTER_ROLE:-postgres_exporter}"
PG_EXPORTER_DB="${PG_EXPORTER_DB:-postgres}"
PG_EXPORTER_CONNLIMIT="${PG_EXPORTER_CONNLIMIT:-5}"
LAN_PROBE_ADDR="${LAN_PROBE_ADDR:-192.168.20.1}"

if [[ -z "${PG_EXPORTER_PASSWORD:-}" ]]; then
  echo "Error: PG_EXPORTER_PASSWORD is required. Run through setup.sh," >&2
  echo "       which generates one and tells you where to store it." >&2
  exit 1
fi

# Prereq guard: this installer is only meaningful where Postgres actually runs.
if ! systemctl is-active --quiet postgresql; then
  echo "Error: postgresql is not running here. This installer targets the" >&2
  echo "       database VM (192.168.20.23), not a generic host." >&2
  exit 1
fi

LAN_IP="$(ip -4 route get "$LAN_PROBE_ADDR" 2>/dev/null \
          | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
if [[ -z "$LAN_IP" ]]; then
  echo "Error: could not derive a LAN address from the route to ${LAN_PROBE_ADDR}" >&2
  exit 1
fi
echo "==> LAN address: ${LAN_IP}"

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
if ! apt-cache policy prometheus-postgres-exporter 2>/dev/null | grep -q 'Candidate: [0-9]'; then
  apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-postgres-exporter
echo "==> Installed $(dpkg-query -W -f='${Version}' prometheus-postgres-exporter)"

# ---------------------------------------------------------------------------
# Monitoring role
# ---------------------------------------------------------------------------
# pg_monitor is a predefined role: it grants read access to the pg_stat_* views
# and the other monitoring functions, and nothing more. The exporter never needs
# to see table contents, so it never gets to.
#
# The connection limit is deliberate. Every application on this host shares one
# max_connections budget, and an exporter that reconnects in a loop during an
# incident is exactly the wrong thing to have uncapped when the pool is already
# the scarce resource. Five is generous for one scraper.
echo "==> Ensuring the ${PG_EXPORTER_ROLE} role..."
#
# CREATE ROLE has no IF NOT EXISTS, and a DO block cannot be used to work
# around that here: psql does not interpolate its variables inside dollar
# quoting, so :'role' would reach the server literally. \gexec is the psql
# idiom for conditional DDL -- the SELECT yields the statement to run, or no
# rows at all when the role already exists.
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -v role="$PG_EXPORTER_ROLE" \
  -v pass="$PG_EXPORTER_PASSWORD" \
  -v db="$PG_EXPORTER_DB" \
  -v connlimit="$PG_EXPORTER_CONNLIMIT" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec

ALTER ROLE :"role" WITH LOGIN
  PASSWORD :'pass'
  CONNECTION LIMIT :connlimit;

GRANT pg_monitor TO :"role";

-- pg_monitor grants the statistics views, not the right to open a connection,
-- and CONNECT has been revoked from PUBLIC on every database on this host
-- (the postgres database reads `=T/postgres`: TEMP only). Without this the
-- exporter authenticates and is then refused with "permission denied for
-- database". One database is enough: pg_stat_database is cluster-wide, so
-- every other database is visible from this one connection.
GRANT CONNECT ON DATABASE :"db" TO :"role";

-- The exporter only ever reads catalog and statistics views, so pinning the
-- search_path removes any chance of a shadowing object in a user schema.
ALTER ROLE :"role" SET search_path = pg_catalog;
SQL

# ---------------------------------------------------------------------------
# Exporter configuration
# ---------------------------------------------------------------------------
# Connects over loopback, which pg_hba already covers with scram-sha-256, so
# nothing here has to touch pg_hba.conf.
#
# --auto-discover-databases is deliberately NOT set. It opens a connection per
# database -- eight of them here -- against the shared connection budget, and
# buys per-table statistics nobody has asked for. pg_stat_database is
# cluster-wide from a single connection and already gives per-database
# connections, commits, rollbacks, block hits and tuple counts.
install -m 0640 -o root -g prometheus /dev/null /etc/default/prometheus-postgres-exporter
cat > /etc/default/prometheus-postgres-exporter <<EOF
# Managed by bootstrap/postgres-exporter/install.sh -- edits here are lost on
# the next run. The password also lives in Infisical under /postgres-exporter/.
DATA_SOURCE_NAME='postgresql://${PG_EXPORTER_ROLE}:${PG_EXPORTER_PASSWORD}@127.0.0.1:5432/${PG_EXPORTER_DB}?sslmode=disable'
ARGS='--web.listen-address=${LAN_IP}:${PG_EXPORTER_PORT}'
EOF
chmod 0640 /etc/default/prometheus-postgres-exporter
chown root:prometheus /etc/default/prometheus-postgres-exporter

systemctl enable --quiet prometheus-postgres-exporter
systemctl restart prometheus-postgres-exporter

# ---------------------------------------------------------------------------
# Smoke check
# ---------------------------------------------------------------------------
sleep 3
# Read into a variable rather than piping into grep: `grep -q` exits on the
# first match, curl takes SIGPIPE, and pipefail turns a healthy exporter into
# a failed install.
metrics="$(curl -sf --max-time 5 "http://${LAN_IP}:${PG_EXPORTER_PORT}/metrics" || true)"
if grep -q '^pg_up 1' <<<"$metrics"; then
  echo "==> OK: exporter answering on ${LAN_IP}:${PG_EXPORTER_PORT}, pg_up=1"
  echo "==> $(grep -c '^pg_' <<<"$metrics") pg_* series exposed"
elif grep -q '^pg_up 0' <<<"$metrics"; then
  echo "Error: exporter is up but cannot reach Postgres (pg_up=0)." >&2
  echo "       Check the role's password and pg_hba for 127.0.0.1." >&2
  systemctl status prometheus-postgres-exporter --no-pager || true
  exit 1
else
  echo "Error: exporter not answering on ${LAN_IP}:${PG_EXPORTER_PORT}" >&2
  systemctl status prometheus-postgres-exporter --no-pager || true
  exit 1
fi
