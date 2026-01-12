#!/bin/bash
#
# Provision a PostgreSQL database with user and strong password
#
# Usage: pg-provision <app_name> [--env staging|prod]
#
# Examples:
#   pg-provision myapp
#   pg-provision myapp --env staging
#   pg-provision myapp --env prod
#
# This script is idempotent - safe to run multiple times.
# If the database/user exists, it will update the password.
#
set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-192.168.20.21}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
INFISICAL_PROJECT="${INFISICAL_PROJECT:-homeserver-1jj1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <app_name> [--env staging|prod]"
    echo ""
    echo "Provisions a PostgreSQL database for an application."
    echo ""
    echo "Arguments:"
    echo "  app_name    Name of the application (used for DB name and user)"
    echo "  --env       Environment (staging or prod). Default: staging"
    echo ""
    echo "Examples:"
    echo "  $0 myapp"
    echo "  $0 myapp --env prod"
    echo "  $0 werify --env staging"
    exit 1
}

# Parse arguments
APP_NAME=""
ENVIRONMENT="staging"

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$APP_NAME" ]]; then
                APP_NAME="$1"
            else
                echo "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$APP_NAME" ]]; then
    echo "Error: app_name is required"
    usage
fi

# Validate environment
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "prod" ]]; then
    echo "Error: --env must be 'staging' or 'prod'"
    exit 1
fi

# Sanitize app name for database naming (lowercase, underscores)
DB_NAME=$(echo "${APP_NAME}_${ENVIRONMENT}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
DB_USER=$(echo "${APP_NAME}_${ENVIRONMENT}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')

# Generate a strong password (32 chars, alphanumeric + special chars)
generate_password() {
    # Generate 32 random bytes, base64 encode, take first 32 chars
    # Remove problematic characters that might cause escaping issues
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#%^&*()_+-=' | head -c 32
}

DB_PASSWORD=$(generate_password)

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  PostgreSQL Database Provisioning${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  App:         ${GREEN}${APP_NAME}${NC}"
echo -e "  Environment: ${GREEN}${ENVIRONMENT}${NC}"
echo -e "  Database:    ${GREEN}${DB_NAME}${NC}"
echo -e "  User:        ${GREEN}${DB_USER}${NC}"
echo -e "  Host:        ${GREEN}${POSTGRES_HOST}:${POSTGRES_PORT}${NC}"
echo ""

# Check if running as postgres user or need sudo
if [[ "$(whoami)" == "postgres" ]]; then
    PSQL="psql"
else
    PSQL="sudo -u postgres psql"
fi

echo -e "${YELLOW}==> Creating database and user (idempotent)...${NC}"

# Create database and user (idempotent SQL)
$PSQL <<EOF
-- Create the user if it doesn't exist, otherwise update password
-- NOSUPERUSER, NOCREATEDB, NOCREATEROLE = minimal privileges
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
        RAISE NOTICE 'Created new user: ${DB_USER}';
    ELSE
        ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
        RAISE NOTICE 'Updated password for existing user: ${DB_USER}';
    END IF;
END
\$\$;

-- Create the database if it doesn't exist
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

-- Grant privileges on this database only
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Revoke connect from PUBLIC on this database (only owner + postgres can connect)
REVOKE CONNECT ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Revoke this user's ability to connect to other system databases
REVOKE CONNECT ON DATABASE postgres FROM ${DB_USER};
REVOKE CONNECT ON DATABASE template1 FROM ${DB_USER};

-- Connect to the database and grant schema privileges
\c ${DB_NAME}

-- Revoke default public schema privileges and grant only to this user
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO ${DB_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
EOF

echo ""
echo -e "${GREEN}✓ Database provisioned successfully!${NC}"
echo ""

# Build the DATABASE_URL
DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB_NAME}"

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  DATABASE_URL${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}${DATABASE_URL}${NC}"
echo ""

# Infisical path based on app name (capitalize first letter for path)
INFISICAL_PATH="/${APP_NAME^}/"
INFISICAL_SECRET_NAME="DATABASE_URL"

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Store in Infisical${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Run this command to store the DATABASE_URL in Infisical:"
echo ""
echo -e "${YELLOW}infisical secrets set ${INFISICAL_SECRET_NAME}=\"${DATABASE_URL}\" \\
    --projectSlug ${INFISICAL_PROJECT} \\
    --env ${ENVIRONMENT} \\
    --secretPath \"${INFISICAL_PATH}\"${NC}"
echo ""
echo -e "Or copy to clipboard (macOS):"
echo ""
echo -e "${YELLOW}echo '${DATABASE_URL}' | pbcopy${NC}"
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
