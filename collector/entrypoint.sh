#!/bin/sh
set -e

# Wait for credentials file from vault-init
echo "Waiting for Dash0 credentials from Vault..."
while [ ! -f /certs/dash0.env ]; do
  sleep 1
done

# Load credentials
echo "Loading Dash0 credentials..."
. /certs/dash0.env
export DASH0_ENDPOINT
export DASH0_AUTH_TOKEN

echo "Dash0 Endpoint: ${DASH0_ENDPOINT}"
echo "Starting OpenTelemetry Collector..."

exec /otelcol-contrib "$@"
