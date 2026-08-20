#!/usr/bin/env bash
# Stand up the admission webhook end to end:
#   CA + server certificate -> TLS Secret -> ConfigMap(server.py)
#   -> Deployment -> Service -> Mutating/ValidatingWebhookConfiguration
#
# Run from the assignment directory:
#   bash solution/webhook/deploy-webhook.sh
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'      # keep Git Bash from mangling -subj "/CN=..."

NS=webhook-demo
SVC=webhook-service
DNS="${SVC}.${NS}.svc"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> 1/5 certificate authority and server certificate for ${DNS}"
openssl genrsa -out "${TMP}/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "${TMP}/ca.key" -days 365 \
  -subj "/CN=admission-webhook-ca" -out "${TMP}/ca.crt" 2>/dev/null

openssl genrsa -out "${TMP}/tls.key" 2048 2>/dev/null
openssl req -new -key "${TMP}/tls.key" -subj "/CN=${DNS}" -out "${TMP}/tls.csr" 2>/dev/null

# The API server matches the SERVICE DNS NAME against the SAN. A certificate with
# only a CN and no subjectAltName is rejected by modern Go TLS -- this extension
# file is not optional.
printf 'subjectAltName=DNS:%s,DNS:%s.%s,DNS:%s\n' "${SVC}" "${SVC}" "${NS}" "${DNS}" > "${TMP}/san.ext"
printf 'extendedKeyUsage=serverAuth\n' >> "${TMP}/san.ext"

openssl x509 -req -in "${TMP}/tls.csr" -CA "${TMP}/ca.crt" -CAkey "${TMP}/ca.key" \
  -CAcreateserial -days 365 -extfile "${TMP}/san.ext" -out "${TMP}/tls.crt" 2>/dev/null

echo "==> 2/5 namespace, TLS secret and the server code as a ConfigMap"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret tls webhook-server-tls -n "${NS}" \
  --cert="${TMP}/tls.crt" --key="${TMP}/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap webhook-server-code -n "${NS}" \
  --from-file=server.py="${HERE}/server.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> 3/5 deployment and service"
kubectl apply -f "${HERE}/../02-webhook-deployment.yaml" >/dev/null
kubectl rollout status deployment/webhook-server -n "${NS}" --timeout=180s

echo "==> 4/5 webhook configurations, with the CA bundle injected"
CA_B64=$(base64 -w0 < "${TMP}/ca.crt" 2>/dev/null || base64 < "${TMP}/ca.crt" | tr -d '\n')
sed "s|CA_BUNDLE_PLACEHOLDER|${CA_B64}|g" "${HERE}/../03-webhook-configuration.yaml" \
  | kubectl apply -f - >/dev/null

echo "==> 5/5 verifying"
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration | grep -i pod-policy || true
echo
echo "done. The webhook now sees every pod CREATE outside kube-system and webhook-demo."
echo "Watch its decisions with:"
echo "   kubectl logs -n ${NS} -l app=webhook-server -f"
