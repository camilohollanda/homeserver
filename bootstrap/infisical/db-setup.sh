#!/usr/bin/env bash
# Runs on the postgres VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.21 ./db-setup.sh
#
# Required env vars:
#   DB_NAME     - Database name (default: infisical)
#   DB_USER     - Database user (default: infisical)
#   DB_PASSWORD - Database password
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      DB_NAME     "${DB_NAME:-infisical}" \
      DB_USER     "${DB_USER:-infisical}" \
      DB_PASSWORD "${DB_PASSWORD:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

DB_NAME="${DB_NAME:-infisical}"
DB_USER="${DB_USER:-infisical}"

if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "Error: DB_PASSWORD is required"
  exit 1
fi

echo "==> Creating Infisical database and user on PostgreSQL..."

sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;

-- Give Infisical priority on the shared instance: members of
-- pg_use_reserved_connections may draw from reserved_connections (set in
-- bootstrap/postgres/install.sh) once the apps have filled the normal pool,
-- so a runaway app pool can't lock Infisical out of its own database.
GRANT pg_use_reserved_connections TO ${DB_USER};

SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

\c ${DB_NAME}
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
SQL

echo "✓ Database '${DB_NAME}' ready for user '${DB_USER}'"
