#!/usr/bin/env bash
# Create a CSR that requests membership of system:masters -- the group bound to
# cluster-admin by default.
#
# APPROVING THIS WOULD HAND OVER THE CLUSTER, permanently, with no revocation
# list. The exercise is to inspect it BEFORE acting and deny it.
#
#   kubectl get csr agent-smith -o jsonpath='{.spec.groups}'
#   kubectl certificate deny agent-smith
#   kubectl delete csr agent-smith
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

openssl genrsa -out "${WORK}/agent-smith.key" 2048 2>/dev/null
openssl req -new -key "${WORK}/agent-smith.key" -out "${WORK}/agent-smith.csr" \
  -subj "/CN=agent-smith/O=system:masters" 2>/dev/null

REQ="$(base64 -w 0 < "${WORK}/agent-smith.csr" 2>/dev/null || base64 < "${WORK}/agent-smith.csr" | tr -d '\n')"

kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: agent-smith
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - client auth
  request: ${REQ}
EOF

cat <<'EOF'

A CSR named `agent-smith` is now Pending. Before you touch it:

  kubectl get csr agent-smith -o jsonpath='{.spec.groups}'

If that contains system:masters, DENY it:

  kubectl certificate deny agent-smith
  kubectl delete csr agent-smith
EOF
