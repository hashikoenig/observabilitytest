#!/bin/sh
set -e

# Wait for vault-init to complete (CA cert is created last)
echo "Waiting for Vault initialization..."
while [ ! -f /certs/ca.crt ]; do
  sleep 1
done

# Check for Dash0 credentials
if [ -f /certs/dash0.env ]; then
  echo "Loading Dash0 credentials..."
  . /certs/dash0.env
  export DASH0_ENDPOINT
  export DASH0_AUTH_TOKEN
  echo "Dash0 Endpoint: ${DASH0_ENDPOINT}"
else
  echo "WARNING: No Dash0 credentials found. Traces will only be logged locally."
  echo "To enable Dash0 export, add credentials to Vault and restart."
fi

echo "Starting OpenTelemetry Collector..."
exec /otelcol-contrib "$@"
