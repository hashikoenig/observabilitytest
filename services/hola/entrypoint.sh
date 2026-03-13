#!/bin/bash
set -e

JAVA_OPTS=""

# Convert PEM certificates to PKCS12 keystore for Java
if [ -n "$TLS_CERT_FILE" ] && [ -n "$TLS_KEY_FILE" ] && [ -n "$TLS_CA_FILE" ]; then
    echo "Converting certificates to PKCS12 format..."

    # Create keystore from cert and key
    openssl pkcs12 -export \
        -in "$TLS_CERT_FILE" \
        -inkey "$TLS_KEY_FILE" \
        -out /tmp/keystore.p12 \
        -name hola \
        -password pass:changeit

    # Create truststore from CA chain (import each cert separately)
    # Split CA chain file and import each certificate
    csplit -f /tmp/ca- -b '%02d.pem' "$TLS_CA_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true

    i=0
    for cert in /tmp/ca-*.pem; do
        if [ -s "$cert" ]; then
            keytool -import \
                -file "$cert" \
                -alias "ca$i" \
                -keystore /tmp/truststore.p12 \
                -storetype PKCS12 \
                -storepass changeit \
                -noprompt 2>/dev/null || true
            i=$((i+1))
        fi
    done

    JAVA_OPTS="-Dserver.ssl.enabled=true \
        -Dserver.ssl.key-store=/tmp/keystore.p12 \
        -Dserver.ssl.key-store-password=changeit \
        -Dserver.ssl.key-store-type=PKCS12 \
        -Dserver.ssl.trust-store=/tmp/truststore.p12 \
        -Dserver.ssl.trust-store-password=changeit \
        -Dserver.ssl.trust-store-type=PKCS12 \
        -Dserver.ssl.client-auth=need"

    echo "Starting hola service on port ${PORT:-8083} with mTLS"
else
    echo "Starting hola service on port ${PORT:-8083} (no TLS)"
fi

exec java $JAVA_OPTS -jar /app/app.jar
