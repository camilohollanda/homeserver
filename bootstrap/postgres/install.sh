#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# PostgreSQL version to install (default: 17)
# Can be overridden via environment variable: POSTGRES_VERSION=15 ./postgres-install.sh
POSTGRES_VERSION="${POSTGRES_VERSION:-17}"

echo "Installing PostgreSQL ${POSTGRES_VERSION} from official repository..."

# Install prerequisites
sudo apt-get update
sudo apt-get install -y wget ca-certificates gnupg lsb-release

# Add PostgreSQL official APT repository
echo "Adding PostgreSQL official repository..."

# Import the repository signing key (modern method)
sudo mkdir -p /etc/apt/keyrings
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
sudo chmod 644 /etc/apt/keyrings/postgresql.gpg

# Create the repository configuration
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

# Update package list
sudo apt-get update

# Install PostgreSQL
echo "Installing PostgreSQL ${POSTGRES_VERSION}..."
sudo apt-get install -y postgresql-${POSTGRES_VERSION} postgresql-contrib-${POSTGRES_VERSION}

# Get the PostgreSQL version (for config paths)
PG_VERSION="${POSTGRES_VERSION}"

# Configure PostgreSQL to listen on all interfaces (for K3s cluster access)
echo "Configuring PostgreSQL to accept connections..."

# Backup original config
sudo cp /etc/postgresql/${PG_VERSION}/main/postgresql.conf /etc/postgresql/${PG_VERSION}/main/postgresql.conf.bak

# Update postgresql.conf to listen on all interfaces
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/${PG_VERSION}/main/postgresql.conf

# Configure pg_hba.conf to allow connections from K3s cluster subnet
# Adjust the subnet (192.168.20.0/24) if your network is different
echo "Configuring pg_hba.conf..."
sudo tee -a /etc/postgresql/${PG_VERSION}/main/pg_hba.conf > /dev/null <<EOF

# Allow connections from K3s cluster
host    all             all             192.168.20.0/24          md5
EOF

# Restart PostgreSQL
sudo systemctl restart postgresql
sudo systemctl enable postgresql

echo ""
echo "✓ PostgreSQL ${POSTGRES_VERSION} installed and configured"
echo ""
echo "PostgreSQL is listening on all interfaces and accepting connections from 192.168.20.0/24"
echo ""
echo "Default database user: postgres"
echo ""
echo "To set a password for the postgres user, run:"
echo "  sudo -u postgres psql -c \"ALTER USER postgres PASSWORD 'your-password';\""
echo ""
echo "To create a new database and user, run:"
echo "  sudo -u postgres psql -c \"CREATE DATABASE your_database;\""
echo "  sudo -u postgres psql -c \"CREATE USER your_user WITH PASSWORD 'your_password';\""
echo "  sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE your_database TO your_user;\""
