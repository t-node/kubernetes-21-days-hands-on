#!/usr/bin/env bash
# Issue a client certificate for a user, signed by the cluster CA.
#
#   bash solution/make-user-cert.sh <username> [group]
#   bash solution/make-user-cert.sh --rogue-ca <username> [group]
#
# The three commands from 13.8, nothing more. With --rogue-ca it signs with a
# throwaway CA instead -- producing a certificate that is perfectly valid and
# that the cluster will refuse, which is the point.
#
# Output goes to /tmp/cka13/.
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

CP=${CP:-devops-control-plane}
OUT=${OUT:-/tmp/cka13}
ROGUE=0
if [ "${1:-}" = "--rogue-ca" ]; then ROGUE=1; shift; fi
USER_NAME=${1:-}
GROUP=${2:-}
[ -n "$USER_NAME" ] || { echo "usage: $0 [--rogue-ca] <username> [group]"; exit 1; }

mkdir -p "$OUT"
SUBJ="/CN=${USER_NAME}"
[ -n "$GROUP" ] && SUBJ="${SUBJ}/O=${GROUP}"

echo "==> 1/3 private key -- this file never leaves your machine"
openssl genrsa -out "${OUT}/${USER_NAME}.key" 2048 2>/dev/null

echo "==> 2/3 certificate signing request, subject ${SUBJ}"
echo "        CN becomes the USERNAME, O becomes the GROUP"
openssl req -new -key "${OUT}/${USER_NAME}.key" -subj "$SUBJ" -out "${OUT}/${USER_NAME}.csr" 2>/dev/null

if [ "$ROGUE" -eq 1 ]; then
  echo "==> 3/3 signing with a ROGUE CA (not the cluster's)"
  if [ ! -f "${OUT}/rogue-ca.crt" ]; then
    openssl genrsa -out "${OUT}/rogue-ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "${OUT}/rogue-ca.key" -days 365 \
      -subj "/CN=definitely-not-kubernetes" -out "${OUT}/rogue-ca.crt" 2>/dev/null
  fi
  openssl x509 -req -in "${OUT}/${USER_NAME}.csr" \
    -CA "${OUT}/rogue-ca.crt" -CAkey "${OUT}/rogue-ca.key" -CAcreateserial \
    -days 365 -out "${OUT}/${USER_NAME}.crt" 2>/dev/null
else
  echo "==> 3/3 signing with the CLUSTER CA (/etc/kubernetes/pki/ca.{crt,key})"
  # ca.key lives only on the control-plane node. Copying it out is exactly what
  # you would never do in production -- holding it IS cluster-admin.
  docker cp "${CP}:/etc/kubernetes/pki/ca.crt" "${OUT}/ca.crt" >/dev/null
  docker cp "${CP}:/etc/kubernetes/pki/ca.key" "${OUT}/ca.key" >/dev/null
  openssl x509 -req -in "${OUT}/${USER_NAME}.csr" \
    -CA "${OUT}/ca.crt" -CAkey "${OUT}/ca.key" -CAcreateserial \
    -days 365 -out "${OUT}/${USER_NAME}.crt" 2>/dev/null
  rm -f "${OUT}/ca.key"
fi

echo
openssl x509 -in "${OUT}/${USER_NAME}.crt" -noout -subject -issuer -dates
echo
echo "Files in ${OUT}:"
ls -1 "${OUT}/${USER_NAME}".* | sed 's/^/    /'
echo
echo "Use it without a kubeconfig:"
echo "    curl --cacert ${OUT}/ca.crt --cert ${OUT}/${USER_NAME}.crt --key ${OUT}/${USER_NAME}.key <apiserver>/api/v1/pods"
