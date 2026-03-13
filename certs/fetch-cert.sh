#!/bin/bash
set -e

SERVICE_NAME=${1:-service}
CERT_DIR=${CERT_DIR:-/certs}
VAULT_ADDR=${VAULT_ADDR:-http://vault:8200}
VAULT_TOKEN=${VAULT_TOKEN:-root}

export VAULT_ADDR
export VAULT_TOKEN

COMMON_NAME="${SERVICE_NAME}.observability.local"

echo "Waiting for Vault PKI to be ready..."
until vault read pki_int/roles/service-cert > /dev/null 2>&1; do
  echo "Waiting for PKI role to be available..."
  sleep 2
done

echo "Fetching certificate for ${COMMON_NAME}..."

# Request certificate from Vault
CERT_DATA=$(vault write -format=json pki_int/issue/service-cert \
  common_name="${COMMON_NAME}" \
  alt_names="localhost,${SERVICE_NAME}" \
  ip_sans="127.0.0.1" \
  ttl=24h)

# Extract and save certificate components
echo "${CERT_DATA}" | jq -r '.data.certificate' > "${CERT_DIR}/${SERVICE_NAME}.crt"
echo "${CERT_DATA}" | jq -r '.data.private_key' > "${CERT_DIR}/${SERVICE_NAME}.key"
echo "${CERT_DATA}" | jq -r '.data.ca_chain[]' > "${CERT_DIR}/${SERVICE_NAME}-ca-chain.crt"

# Set proper permissions
chmod 644 "${CERT_DIR}/${SERVICE_NAME}.crt"
chmod 600 "${CERT_DIR}/${SERVICE_NAME}.key"
chmod 644 "${CERT_DIR}/${SERVICE_NAME}-ca-chain.crt"

echo "Certificate for ${SERVICE_NAME} saved to ${CERT_DIR}/"
echo "  - ${SERVICE_NAME}.crt (certificate)"
echo "  - ${SERVICE_NAME}.key (private key)"
echo "  - ${SERVICE_NAME}-ca-chain.crt (CA chain)"
