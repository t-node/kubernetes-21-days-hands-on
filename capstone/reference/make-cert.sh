#!/usr/bin/env bash
# Generate a self-signed TLS certificate and store it as a kubernetes.io/tls
# Secret for the Ingress.
#
# IN PRODUCTION YOU WOULD NOT DO THIS. Install cert-manager, add
#   cert-manager.io/cluster-issuer: letsencrypt-prod
# to the Ingress, and let it obtain and renew real certificates. Nobody wants a
# 90-day renewal on a calendar.
set -euo pipefail
NS=devboard
HOST=devboard.local
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> generating a self-signed certificate for ${HOST}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMP}/tls.key" -out "${TMP}/tls.crt" \
  -subj "/CN=${HOST}/O=devboard" \
  -addext "subjectAltName=DNS:${HOST},DNS:*.${HOST}" 2>/dev/null

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret tls devboard-tls -n "${NS}" \
  --cert="${TMP}/tls.crt" --key="${TMP}/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secret devboard-tls created in namespace ${NS}."
echo "The certificate is self-signed, so browsers will warn. Use curl -k, or"
echo "add an exception."
