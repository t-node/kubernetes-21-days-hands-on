#!/usr/bin/env bash
# End-to-end user onboarding through the Certificates API.
#
#   ./onboard-user.sh akshay developers devboard
#
# Produces a working kubeconfig at /tmp/cka05/<user>.kubeconfig, then shows that
# it authenticates but is NOT authorised until you bind a Role.
set -euo pipefail
USER_NAME="${1:?usage: ./onboard-user.sh <user> <group> [namespace]}"
GROUP="${2:?usage: ./onboard-user.sh <user> <group> [namespace]}"
NS="${3:-devboard}"
WORK=/tmp/cka05
mkdir -p "$WORK"; cd "$WORK"

echo "==> 1. key + CSR for CN=${USER_NAME}, O=${GROUP}"
openssl genrsa -out "${USER_NAME}.key" 2048 2>/dev/null
openssl req -new -key "${USER_NAME}.key" -out "${USER_NAME}.csr" \
  -subj "/CN=${USER_NAME}/O=${GROUP}" 2>/dev/null

echo "==> 2. submitting the CertificateSigningRequest"
REQ="$(base64 -w 0 < "${USER_NAME}.csr" 2>/dev/null || base64 < "${USER_NAME}.csr" | tr -d '\n')"
kubectl apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
  request: ${REQ}
EOF

echo "==> 3. groups requested (review before approving):"
kubectl get csr "${USER_NAME}" -o jsonpath='{.spec.groups}'; echo

echo "==> 4. approving"
kubectl certificate approve "${USER_NAME}" >/dev/null
sleep 2
kubectl get csr "${USER_NAME}"

echo "==> 5. extracting the issued certificate"
kubectl get csr "${USER_NAME}" -o jsonpath='{.status.certificate}' | base64 -d > "${USER_NAME}.crt"
openssl x509 -in "${USER_NAME}.crt" -noout -subject -dates

echo "==> 6. building ${WORK}/${USER_NAME}.kubeconfig"
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
SERVER="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
KC="${WORK}/${USER_NAME}.kubeconfig"
rm -f "$KC"
kubectl config --kubeconfig="$KC" set-cluster devops \
  --server="$SERVER" --certificate-authority="${WORK}/ca.crt" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$KC" set-credentials "${USER_NAME}" \
  --client-certificate="${WORK}/${USER_NAME}.crt" \
  --client-key="${WORK}/${USER_NAME}.key" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$KC" set-context "${USER_NAME}@devops" \
  --cluster=devops --user="${USER_NAME}" --namespace="${NS}" >/dev/null
kubectl config --kubeconfig="$KC" use-context "${USER_NAME}@devops" >/dev/null

cat <<EOF

Done. The certificate AUTHENTICATES but grants NOTHING:

  kubectl --kubeconfig=${KC} get pods
  -> Forbidden  (not Unauthorized -- the cluster knows exactly who this is)

Grant permissions by user:

  kubectl create rolebinding ${USER_NAME}-view --clusterrole=view --user=${USER_NAME} -n ${NS}

...or better, by GROUP, so every future ${GROUP} member works on day one:

  kubectl create rolebinding ${GROUP}-view --clusterrole=view --group=${GROUP} -n ${NS}
EOF
