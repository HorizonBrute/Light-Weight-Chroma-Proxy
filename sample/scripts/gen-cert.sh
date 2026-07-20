#!/usr/bin/env bash
# Generate a self-signed TLS cert + key for the proxy edge.
#
#   - SAN covers DNS:localhost and IP:127.0.0.1 (so `curl https://127.0.0.1:8443`
#     and https://localhost:8443 both validate against the SAN if you trust it).
#   - 3650-day validity (self-signed; rotate by re-running).
#   - key file locked to mode 600.
#
# Output goes to sample/certs/{cert.pem,key.pem}, which compose mounts read-only
# into the proxy at /etc/nginx/certs.
#
# BRING YOUR OWN CERT: skip this script and just drop your real cert.pem + key.pem
# into sample/certs/ (same filenames). Nothing else changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/certs"
mkdir -p "${CERT_DIR}"

CERT="${CERT_DIR}/cert.pem"
KEY="${CERT_DIR}/key.pem"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${KEY}" \
    -out "${CERT}" \
    -days 3650 \
    -subj "/CN=localhost/O=Lightweight Secure Chroma Proxy Demo" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "${KEY}"
chmod 644 "${CERT}"

echo "Wrote:"
echo "  ${CERT}"
echo "  ${KEY}  (mode 600)"
echo
echo "SAN:"
openssl x509 -in "${CERT}" -noout -ext subjectAltName | sed 's/^/  /'
