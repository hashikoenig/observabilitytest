#!/bin/bash
set -e

VAULT_ADDR=${VAULT_ADDR:-http://vault:8200}
VAULT_TOKEN=${VAULT_TOKEN:-root}

export VAULT_ADDR
export VAULT_TOKEN

echo "Waiting for Vault to be ready..."
until curl -s ${VAULT_ADDR}/v1/sys/health > /dev/null 2>&1; do
  sleep 1
done

echo "Vault is ready. Configuring PKI..."

# Enable PKI secrets engine for Root CA
vault secrets enable -path=pki pki 2>/dev/null || echo "PKI already enabled"

# Configure Root CA max lease TTL (10 years)
vault secrets tune -max-lease-ttl=87600h pki

# Generate Root CA
vault write -format=json pki/root/generate/internal \
  common_name="Observability Root CA" \
  ttl=87600h > /dev/null 2>&1 || echo "Root CA already exists"

# Configure CA and CRL URLs
vault write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"

# Enable PKI secrets engine for Intermediate CA
vault secrets enable -path=pki_int pki 2>/dev/null || echo "PKI Int already enabled"

# Configure Intermediate CA max lease TTL (5 years)
vault secrets tune -max-lease-ttl=43800h pki_int

# Generate Intermediate CA CSR
vault write -format=json pki_int/intermediate/generate/internal \
  common_name="Observability Intermediate CA" \
  | jq -r '.data.csr' > /tmp/pki_int.csr 2>/dev/null || echo "Intermediate CSR already exists"

# Sign Intermediate CA with Root CA
if [ -f /tmp/pki_int.csr ] && [ -s /tmp/pki_int.csr ]; then
  vault write -format=json pki/root/sign-intermediate \
    csr=@/tmp/pki_int.csr \
    format=pem_bundle \
    ttl=43800h \
    | jq -r '.data.certificate' > /tmp/intermediate.cert.pem

  # Import signed Intermediate certificate
  vault write pki_int/intermediate/set-signed \
    certificate=@/tmp/intermediate.cert.pem
fi

# Create role for service certificates
vault write pki_int/roles/service-cert \
  allowed_domains="observability.local,localhost,gateway,greeter,echo,hola" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_localhost=true \
  allow_ip_sans=true \
  max_ttl=72h \
  ttl=24h \
  key_type=rsa \
  key_bits=2048 \
  require_cn=true \
  cn_validations="disabled"

echo "PKI configuration complete!"

# Export CA chain for services
echo "Exporting CA chain..."
vault read -format=json pki/cert/ca | jq -r '.data.certificate' > /certs/ca.crt
vault read -format=json pki_int/cert/ca | jq -r '.data.certificate' >> /certs/ca.crt

echo "CA chain exported to /certs/ca.crt"

# Enable KV secrets engine for application secrets
echo "Configuring KV secrets engine..."
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "KV secrets engine already enabled"

# Load Dash0 credentials from secrets file if it exists
if [ -f /secrets/dash0.env ]; then
  echo "Loading Dash0 credentials from /secrets/dash0.env..."
  # Source the file to get variables (skip comments)
  eval $(grep -v '^#' /secrets/dash0.env | grep '=' | xargs)

  if [ -n "$DASH0_AUTH_TOKEN" ] && [ -n "$DASH0_ENDPOINT" ]; then
    echo "Storing Dash0 credentials in Vault..."
    vault kv put secret/dash0 \
      endpoint="$DASH0_ENDPOINT" \
      auth_token="$DASH0_AUTH_TOKEN"
    echo "Dash0 credentials stored in Vault"
  fi
fi

# Read Dash0 credentials from Vault and write to file for collector
echo "Checking for Dash0 credentials in Vault..."
DASH0_SECRET=$(vault kv get -format=json secret/dash0 2>/dev/null || echo "")

if [ -n "$DASH0_SECRET" ] && [ "$DASH0_SECRET" != "" ]; then
  DASH0_ENDPOINT=$(echo "$DASH0_SECRET" | jq -r '.data.data.endpoint // empty')
  DASH0_AUTH_TOKEN=$(echo "$DASH0_SECRET" | jq -r '.data.data.auth_token // empty')

  if [ -n "$DASH0_ENDPOINT" ] && [ -n "$DASH0_AUTH_TOKEN" ]; then
    echo "Writing Dash0 credentials to /certs/dash0.env..."
    cat > /certs/dash0.env << EOF
DASH0_ENDPOINT=${DASH0_ENDPOINT}
DASH0_AUTH_TOKEN=${DASH0_AUTH_TOKEN}
EOF
    echo "Dash0 credentials written to /certs/dash0.env"
  else
    echo "WARNING: Dash0 credentials incomplete in Vault."
  fi
else
  echo "NOTE: No Dash0 credentials found."
  echo "Create secrets/dash0.env with:"
  echo "  DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317"
  echo "  DASH0_AUTH_TOKEN=your-token-here"
fi

echo ""
echo "=========================================="
echo "Vault UI: http://localhost:8200"
echo "Vault Token: root"
echo "=========================================="
echo "Vault setup complete!"
