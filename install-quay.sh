#!/bin/bash

# --- VARIABLES ---
QUAY_VERSION="3.15.1"
QUAY_IMAGE="registry.redhat.io/quay/quay-rhel8:v${QUAY_VERSION}"
QUAY_CONFIG_DIR="$(pwd)/config"
QUAY_STORAGE_DIR="$(pwd)/storage"
QUAY_FQDN="quay.lab.local"
QUAY_IP="192.168.0.30"
QUAY_POSTGRES_DIR="$(pwd)/postgres-quay"
QUAY_POSTGRES_USRPWD=""
QUAY_POSTGRES_ADMINPWD=""
QUAY_REDIS_PWD=""

CONTAINER_NAME="quay"

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

# --- CHECK FOR PREREQUISITES ---
if ! command -v sudo podman &> /dev/null; then
    echo "Podman is not installed. Please install it first."
    exit 1
fi

# --- SETUP POSTGRES DATABASE ---
echo "Starting up Postgres..."
sudo mkdir -p "$QUAY_POSTGRES_DIR"
sudo setfacl -m u:26:-wx $QUAY_POSTGRES_DIR
sudo podman run -d --rm --name postgresql \
  -e POSTGRESQL_USER=quayuser \
  -e POSTGRESQL_PASSWORD="$QUAY_POSTGRES_USRPWD" \
  -e PGPASSWORD="$QUAY_POSTGRES_USRPWD" \
  -e POSTGRESQL_DATABASE=quay \
  -e POSTGRESQL_ADMIN_PASSWORD="$QUAY_POSTGRES_ADMINPWD" \
  -p 5432:5432 \
  -v $QUAY_POSTGRES_DIR:/var/lib/pgsql/data:Z \
  registry.redhat.io/rhel8/postgresql-13

#--- FIX POSTGRES MISSING EXTENSION ---
echo "Waiting for Postgresql to start..."
sleep 10
sudo podman exec postgresql psql -U "quayuser" -d "quay" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

# --- SETUP REDIS ---
echo "Starting up Redis..."
sudo podman run -d --rm --name redis \
  -p 6379:6379 \
  -e REDIS_PASSWORD="$QUAY_REDIS_PWD" \
  registry.redhat.io/rhel8/redis-6:1-110

# --- SETUP DIRECTORIES AND COPY FILES ---
echo "Setting up Quay directories..."
sudo mkdir -p "$QUAY_CONFIG_DIR"
sudo mkdir -p "$QUAY_STORAGE_DIR"
sudo setfacl -m u:1001:-wx $QUAY_STORAGE_DIR

sudo cat << EOF > config.yaml
BUILDLOGS_REDIS:
    host: $QUAY_FQDN
    password: $QUAY_REDIS_PWD
    port: 6379
CREATE_NAMESPACE_ON_PUSH: true
DATABASE_SECRET_KEY: a8c2744b-7004-4af2-bcee-e417e7bdd235
DB_URI: postgresql://quayuser:$QUAY_POSTGRES_USRPWD@$QUAY_FQDN:5432/quay
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
    password: $QUAY_REDIS_PWD
    port: 6379
EOF

# --- PREPARE CONFIG FILES ---
echo "Copying configuration and SSL files..."
sudo cat rootCA.pem >> ssl.cert
sudo chown root:root config.yaml
sudo chown root:root ssl.cert
sudo chown root:root ssl.key
sudo chmod 644 ssl.key
sudo cp config.yaml "$QUAY_CONFIG_DIR"/
sudo cp ssl.cert "$QUAY_CONFIG_DIR"/
sudo cp ssl.key "$QUAY_CONFIG_DIR"/

# --- CHECK FOR CONFIG AND CERT FILES ---
if [ ! -f "$QUAY_CONFIG_DIR/ssl.cert" ] || [ ! -f "$QUAY_CONFIG_DIR/ssl.key" ] || [ ! -f "$QUAY_CONFIG_DIR/config.yaml" ]; then
    echo "Required files (ssl.cert, ssl.key, config.yaml) not found in the current directory."
    exit 1
fi

# --- START QUAY CONTAINER ---
echo "Starting Red Hat Quay container..."

# Pull the Quay image
sudo podman pull "$QUAY_IMAGE"

# Run the new container with SSL/TLS ports
sudo podman run -d --restart=always \
  --name "$CONTAINER_NAME" \
  -p 443:8443 \
  -v "$QUAY_CONFIG_DIR":/conf/stack:Z \
  -v "$QUAY_STORAGE_DIR":/datastorage:Z \
  "$QUAY_IMAGE"

# --- VERIFY STATUS ---
echo "Waiting for Quay to start..."
sleep 20
sudo podman ps -a --filter "name=$CONTAINER_NAME"

echo "Quay server should now be running with SSL enabled. You can access it at https://$(grep SERVER_HOSTNAME config.yaml | awk '{print $2}')"