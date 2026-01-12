#!/usr/bin/env bash
#
# Setup Infisical database on the PostgreSQL VM
# Run this script on the db-postgres VM (192.168.20.21)
#
# Usage: ./infisical-db-setup.sh <db_name> <db_user> <db_password>
#
set -euo pipefail

DB_NAME="${1:-infisical}"
DB_USER="${2:-infisical}"
DB_PASSWORD="${3:-}"

if [[ -z "$DB_PASSWORD" ]]; then
    echo "Usage: $0 <db_name> <db_user> <db_password>"
    echo "Example: $0 infisical infisical 'your-secure-password'"
    exit 1
fi

echo "==> Creating Infisical database and user..."

# Check if running as postgres user or need sudo
if [[ "$(whoami)" == "postgres" ]]; then
    PSQL="psql"
else
    PSQL="sudo -u postgres psql"
fi

# Create database and user
$PSQL <<EOF
-- Create the user if it doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    ELSE
        ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    END IF;
END
\$\$;

-- Create the database if it doesn't exist
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the database and grant schema privileges
\c ${DB_NAME}
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
EOF

echo "==> Database setup complete!"
echo ""
echo "Connection string:"
echo "  postgres://${DB_USER}:****@192.168.20.21:5432/${DB_NAME}"
echo ""
echo "Make sure PostgreSQL is configured to accept connections from the Infisical VM:"
echo "  1. Edit /etc/postgresql/*/main/postgresql.conf:"
echo "     listen_addresses = '*'"
echo ""
echo "  2. Edit /etc/postgresql/*/main/pg_hba.conf and add:"
echo "     host    ${DB_NAME}    ${DB_USER}    192.168.20.22/32    scram-sha-256"
echo ""
echo "  3. Restart PostgreSQL:"
echo "     sudo systemctl restart postgresql"
