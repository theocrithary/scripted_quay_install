#!/bin/bash

# ==============================================================================
# Proof of Concept - Deploying Red Hat Quay with Podman on RHEL 9.6
#
# This script automates the full setup of a Red Hat Quay 3.16 container registry
# on an RHEL 9.6 server using Podman.
#
# It performs the following steps:
# 1. Installs necessary dependencies and configures the system.
# 2. Generates self-signed SSL/TLS certificates.
# 3. Sets up PostgreSQL database container for Quay.
# 4. Sets up Redis containers for Quay's backend.
# 5. Configures and deploys the Quay container with SSL enabled.
#
# IMPORTANT: This script requires root privileges. Please run with sudo.

# ALSO IMPORTANT: add execute permissions with: sudo chmod +x install-quay.sh

#  How to use the modified script with the Red Hat login
# export REDHAT_USER=your_redhat_username
# export REDHAT_PASSWORD=your_redhat_password
# sudo ./install-quay.sh

# Or pass flags
# sudo ./install-quay.sh -U your_redhat_username -P your_redhat_password

# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# Ensure we're running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit
fi

# ================================
# User configurable variables
# ================================

QUAY_VERSION="3.16.0"
QUAY_IMAGE="registry.redhat.io/quay/quay-rhel9:v${QUAY_VERSION}"
QUAY_CONFIG_DIR="$(pwd)/config"
QUAY_STORAGE_DIR="$(pwd)/storage"
QUAY_FQDN="quay.lab.local"
QUAY_IP="192.168.0.30"
POSTGRES_DIR="$(pwd)/postgres-quay"
POSTGRES_USR="quayuser"
POSTGRES_PWD=""
POSTGRES_IMAGE="registry.redhat.io/rhel9/postgresql-15"
REDIS_PWD=""
REDIS_IMAGE="registry.redhat.io/rhel9/redis-6:latest"


# ================================
# Helper functions for logging with timestamps and elapsed time
# ================================
# Helper: print elapsed time since script start in human-friendly form
elapsed_since() {
  # elapsed since given timestamp (seconds)
  local since_ts=$1
  local now=$(date +%s)
  local diff=$((now - since_ts))
  local hours=$((diff / 3600))
  local mins=$(((diff % 3600) / 60))
  local secs=$((diff % 60))
  printf "%02dh:%02dm:%02ds" "$hours" "$mins" "$secs"
}

# Helper: log section start with timestamp and elapsed time since previous section
log_section_start() {
  local section_title="$1"
  local now_human=$(timestamp)
  local elapsed_since_prev=$(elapsed_since "$SECTION_START_TS")
  echo ""
  echo " # ========================================================================================================= "
  echo " # ---> [${now_human}] Starting: ${section_title} (since previous: ${elapsed_since_prev})"
  echo " # ========================================================================================================= "
   # update SECTION_START_TS to now for the next section
  SECTION_START_TS=$(date +%s)
}

# Helper: print a timestamp
timestamp() {
  date --iso-8601=seconds
}

# Record script start time for elapsed calculations
SCRIPT_START_TS=$(date +%s)
SCRIPT_START_TIME_HUMAN=$(date --iso-8601=seconds)
echo "Script started at: ${SCRIPT_START_TIME_HUMAN}"

# Track last section start time so we can report elapsed time between sections
SECTION_START_TS=${SCRIPT_START_TS}

# ================================
# 1. Pre-requisites and Host Prep
# ================================
log_section_start "1. Pre-requisites and Host Prep"
echo "--> Preparing the host system..."

# Parse Red Hat credentials from environment variables or script flags
# You can provide REDHAT_USER and REDHAT_PASSWORD as environment variables or
# pass them as flags to the script: -U <user> -P <password>
while getopts ":U:P:" opt; do
  case $opt in
    U) PARSE_REDHAT_USER="$OPTARG";;
    P) PARSE_REDHAT_PASSWORD="$OPTARG";;
    \?) echo "Invalid option: -$OPTARG"; exit 1;;
  esac
done

# Prefer environment variables if set, otherwise use parsed flags
REDHAT_USER="${REDHAT_USER:-$PARSE_REDHAT_USER}"
REDHAT_PASSWORD="${REDHAT_PASSWORD:-$PARSE_REDHAT_PASSWORD}"

if [ -z "$REDHAT_USER" ] || [ -z "$REDHAT_PASSWORD" ]; then
  echo "ERROR: Red Hat credentials are required to avoid rate limits."
  echo "Set REDHAT_USER and REDHAT_PASSWORD environment variables or pass -U <user> -P <password> to the script."
  exit 1
fi

# Check if Podman is installed
if command -v sudo podman &> /dev/null; then
    echo "✅ Podman is already installed."
else
    echo "❌ Missing package:   podman "
    echo "--> Installing now..."
    yum install -y podman
fi

# Login to Red Hat Container Registry
echo "--> Logging into Red Hat Container Registry..."
sudo podman login registry.redhat.io --username=$REDHAT_USER --password=$REDHAT_PASSWORD

# Disable the firewall to prevent networking issues
if systemctl status firewalld | grep -q "Active: inactive"; then
    echo "✅ Success: Firewall is already disabled."
else
    echo "❌ Failure: Firewall is currently active."
    echo "--> Disabling the firewall..."
    systemctl stop firewalld
    systemctl disable firewalld
    systemctl mask firewalld
fi

# ============================================
# 2. Prepare SSL/TLS Certificates
# ============================================
log_section_start "2. Prepare SSL/TLS Certificates"
echo "--> Generating self-signed SSL/TLS certificates..."

# Check if SSL files already exist
if [ -f "ssl.cert" ] && [ -f "ssl.key" ]; then
    echo "✅ SSL certificate and key files already exist. Skipping generation."
else
    echo "❌ SSL certificate and/or key files not found. Generating now..."
    # --- CREATE CA FILES ---
    openssl genrsa -out rootCA.key 2048
    cat << EOF > root-ca.cnf
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_ca

[ req_distinguished_name ]
C = AU
ST = NSW
L = Sydney
O = Bahay
CN = Quay

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
    openssl req -x509 -new -sha256 -nodes -key rootCA.key -out rootCA.pem -days 3650 -config root-ca.cnf
    # --- CREATE SERVER CERT FILES ---
    openssl genrsa -out ssl.key 2048
    cat << EOF > csr.cnf
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = AU
ST = NSW
L = Sydney
O = Bahay
OU = Quay
CN = Quay

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $QUAY_FQDN
IP.1 = $QUAY_IP
EOF
    openssl req -new -sha256 -key ssl.key -out ssl.csr -config csr.cnf
    cat << EOF > ssl.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $QUAY_FQDN
IP.1 = $QUAY_IP
EOF
    openssl x509 -req -in ssl.csr -CA rootCA.pem -CAkey rootCA.key -CAcreateserial -out ssl.cert -days 356 -extensions v3_req -extfile ssl.cnf
    echo "✅ Successfully generated SSL certificate and key files."
fi

# ============================================
# 3. Install PostgreSQL database
# ============================================
log_section_start "3. Install PostgreSQL database"
echo "--> Checking if PostgreSQL is installed..."

# Check if PostgreSQL container is already running
if podman ps -a --format "{{.Names}}" | grep -q "^quay-postgresql$"; then
    echo "✅ PostgreSQL container is already installed."
else
    echo "❌ PostgreSQL container not found. Installing now..."
    mkdir -p $POSTGRES_DIR
    setfacl -m u:26:-wx $POSTGRES_DIR
    #--- START POSTGRESQL CONTAINER ---
    echo "Starting up Postgresql..."
    podman run -d --rm --name quay-postgresql \
      -e POSTGRESQL_USER=$POSTGRES_USR \
      -e POSTGRESQL_PASSWORD=$POSTGRES_PWD \
      -e POSTGRESQL_DATABASE=quay \
      -e POSTGRESQL_ADMIN_PASSWORD=$POSTGRES_PWD \
      -p 5432:5432 \
      -v $POSTGRES_DIR:/var/lib/pgsql/data:Z \
      $POSTGRES_IMAGE
    echo "Waiting for Postgresql to start..."
    sleep 10
    if podman ps -a --format "{{.Names}}" | grep -q "^quay-postgresql$"; then
        echo "✅ Successfully installed PostgreSQL container."
    else
        echo "❌ Failed to install PostgreSQL container."
        exit 1
    fi
fi

#--- FIX POSTGRES MISSING EXTENSION ---
if podman exec -it quay-postgresql /bin/bash -c 'psql -d quay -U postgres -c "\dx"' | grep -q "pg_trgm"; then
    echo "✅ pg_trgm extension already exists in the database."
else
    echo "❌ pg_trgm extension not found. Creating now..."
    podman exec -it quay-postgresql /bin/bash -c 'echo "CREATE EXTENSION IF NOT EXISTS pg_trgm" | psql -d quay -U postgres'
    echo "✅ Successfully created pg_trgm extension."
fi

# ============================================
# 4. Install Redis database
# ============================================
log_section_start "4. Install Redis database"
echo "--> Checking if Redis is installed..."

# Check if Redis container is already running
if podman ps -a --format "{{.Names}}" | grep -q "^quay-redis$"; then
    echo "✅ Redis container is already installed."
else
    echo "❌ Redis container not found. Installing now..."
    # --- START REDIS CONTAINER ---
    echo "Starting up Redis..."
    podman run -d --rm --name quay-redis \
      -p 6379:6379 \
      -e REDIS_PASSWORD=$REDIS_PWD \
      $REDIS_IMAGE
    echo "Waiting for Redis to start..."
    sleep 5
    if podman ps -a --format "{{.Names}}" | grep -q "^quay-redis$"; then
        echo "✅ Successfully installed Redis container."
    else
        echo "❌ Failed to install Redis container."
        exit 1
    fi
fi

# ============================================
# 5. Install Quay container
# ============================================
log_section_start "5. Install Quay container"
echo "--> Checking if Quay is installed..."

# --- SETUP DIRECTORIES ---
if [ -d "$QUAY_CONFIG_DIR" ]; then
    echo "✅ Quay configuration directory already exists."
else
    echo "❌ Quay configuration directory not found. Creating now..."
    echo "Setting up Quay config directory..."
    mkdir -p "$QUAY_CONFIG_DIR"
fi

if [ -d "$QUAY_STORAGE_DIR" ]; then
    echo "✅ Quay storage directory already exists."
else
    echo "❌ Quay storage directory not found. Creating now..."
    echo "Setting up Quay storage directory..."
    mkdir -p "$QUAY_STORAGE_DIR"
    setfacl -m u:1001:-wx $QUAY_STORAGE_DIR
fi

# --- PREPARE QUAY CONFIGURATION FILE ---
if [ -f "$QUAY_CONFIG_DIR/config.yaml" ]; then
    echo "✅ Quay configuration file already exists."
else
    echo "❌ Quay configuration file not found. Preparing now..."
    cat << EOF > "config.yaml"
BUILDLOGS_REDIS:
    host: $QUAY_FQDN
    password: $REDIS_PWD
    port: 6379
CREATE_NAMESPACE_ON_PUSH: true
DATABASE_SECRET_KEY: a8c2744b-7004-4af2-bcee-e417e7bdd235
DB_URI: postgresql://$POSTGRES_USR:$POSTGRES_PWD@$QUAY_FQDN:5432/quay
DISTRIBUTED_STORAGE_CONFIG:
    default:
        - LocalStorage
        - storage_path: /datastorage
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
DISTRIBUTED_STORAGE_PREFERENCE:
    - default
FEATURE_MAILING: false
SECRET_KEY: e9bd34f4-900c-436a-979e-7530e5d74ac8
SERVER_HOSTNAME: $QUAY_FQDN
PREFERRED_URL_SCHEME: https
SETUP_COMPLETE: true
SUPER_USERS:
  - quayadmin
USER_EVENTS_REDIS:
    host: $QUAY_FQDN
    password: $REDIS_PWD
    port: 6379
EOF
    echo "✅ Successfully prepared Quay configuration file."
fi

# --- CHECK FOR CONFIG AND CERT FILES ---
if [ ! -f "$QUAY_CONFIG_DIR/ssl.cert" ] || [ ! -f "$QUAY_CONFIG_DIR/ssl.key" ] || [ ! -f "$QUAY_CONFIG_DIR/config.yaml" ]; then
    echo "❌ Required files (ssl.cert, ssl.key, config.yaml) not found in the Quay config directory."
    # Check in the current directory for the required files
    if [ ! -f "./rootCA.pem" ] || [ ! -f "./ssl.cert" ] || [ ! -f "./ssl.key" ] || [ ! -f "./config.yaml" ]; then
        echo "❌ Required files (rootCA.pem, ssl.cert, ssl.key, config.yaml) not found in the current directory."
        echo "Please ensure these files are present before proceeding."
        exit 1
    else
        echo "✅ Required files (rootCA.pem, ssl.cert, ssl.key, config.yaml) found."
        echo "Proceeding to copy files to Quay configuration directory."
        # Copy configuration and SSL files to Quay config directory
        cat rootCA.pem >> ssl.cert
        chown root:root config.yaml
        chown root:root ssl.cert
        chown root:root ssl.key
        chmod 644 ssl.key
        cp config.yaml "$QUAY_CONFIG_DIR"/
        cp ssl.cert "$QUAY_CONFIG_DIR"/
        cp ssl.key "$QUAY_CONFIG_DIR"/
        echo "✅ Successfully copied required files to Quay configuration directory."
    fi
fi


# --- START QUAY CONTAINER ---
echo "Starting Red Hat Quay container..."

# Check if Quay container is already running
if podman ps -a --format "{{.Names}}" | grep -q "^quay$"; then
    echo "✅ Quay container is already installed."
else
    echo "❌ Quay container not found. Installing now..."
    if podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${QUAY_IMAGE}$"; then
        echo "✅ Quay image already exists locally."
    else
        echo "❌ Quay image not found locally. Pulling now..."
        # Pull the Quay image
        podman pull "$QUAY_IMAGE"
    fi    
    # Run the new container with SSL/TLS ports
    podman run -d --rm -p 443:8443  \
      --name="quay" \
      -v "$QUAY_CONFIG_DIR":/conf/stack:Z \
      -v "$QUAY_STORAGE_DIR":/datastorage:Z \
      "$QUAY_IMAGE"
    # --- VERIFY STATUS ---
    echo "Waiting for Quay to start..."
    sleep 20
    # --- FINAL CHECK ---
    if podman ps -a --format "{{.Names}}" | grep -q "^quay$"; then
        echo "✅ Successfully installed Red Hat Quay container."
    else
        echo "❌ Failed to install Red Hat Quay container."
        exit 1
    fi
fi

# ============================================
# Installation Complete
# ============================================
log_section_start "Installation Complete"
podman ps -a

echo " # =========================================================================== "
echo "Quay server should now be running with SSL enabled."
echo "You can access it at https://$QUAY_FQDN"
echo "Create an admin user with the username 'quayadmin' during the initial setup."
echo " # =========================================================================== "