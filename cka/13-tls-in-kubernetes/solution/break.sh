#!/usr/bin/env bash
# Break the control plane in a specific, certificate-related way.
#
#   bash solution/break.sh 1     etcd points at a certificate file that does not exist
#   bash solution/break.sh 2     the API server verifies etcd with the WRONG CA
#   bash solution/break.sh 3     the API server's serving certificate is replaced
#                                with one signed by an unknown CA
#
# Recover with:  bash solution/restore.sh
#
# Each scenario takes the control plane DOWN. That is intentional -- you cannot
# learn to read crictl logs on a healthy cluster.
set -euo pipefail
CP=${CP:-devops-control-plane}
MDIR=/etc/kubernetes/manifests

docker exec "$CP" test -d /root/manifests.backup 2>/dev/null || {
  echo "-- taking a first-time backup of $MDIR -> /root/manifests.backup"
  docker exec "$CP" cp -r "$MDIR" /root/manifests.backup
}

case "${1:-}" in
  1)
    echo "==> scenario 1: pointing etcd at a file that does not exist"
    docker exec "$CP" sed -i 's|--cert-file=/etc/kubernetes/pki/etcd/server.crt|--cert-file=/etc/kubernetes/pki/etcd/server-certificate.crt|' \
      "$MDIR/etcd.yaml"
    docker exec "$CP" grep -- "--cert-file" "$MDIR/etcd.yaml"
    echo
    echo "Wait ~30s, then start with:  kubectl get nodes"
    echo "When that fails:            docker exec $CP crictl ps -a | grep -E 'apiserver|etcd'"
    ;;
  2)
    echo "==> scenario 2: making the API server verify etcd with the Kubernetes CA"
    docker exec "$CP" sed -i 's|--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt|--etcd-cafile=/etc/kubernetes/pki/ca.crt|' \
      "$MDIR/kube-apiserver.yaml"
    docker exec "$CP" grep -- "--etcd-cafile" "$MDIR/kube-apiserver.yaml"
    echo
    echo "Wait ~40s. Read BOTH sides -- the API server and etcd each report a"
    echo "different half of the same problem, and neither names a file."
    ;;
  3)
    echo "==> scenario 3: replacing the API server serving certificate with an untrusted one"
    docker exec "$CP" sh -c '
      set -e
      cd /etc/kubernetes/pki
      cp apiserver.crt /root/apiserver.crt.orig
      cp apiserver.key /root/apiserver.key.orig
      openssl genrsa -out /tmp/rogue-ca.key 2048 2>/dev/null
      openssl req -x509 -new -nodes -key /tmp/rogue-ca.key -days 30 \
        -subj "/CN=rogue-ca" -out /tmp/rogue-ca.crt 2>/dev/null
      openssl genrsa -out /tmp/rogue.key 2048 2>/dev/null
      openssl req -new -key /tmp/rogue.key -subj "/CN=kube-apiserver" -out /tmp/rogue.csr 2>/dev/null
      printf "subjectAltName=DNS:kubernetes,DNS:kubernetes.default,IP:127.0.0.1\n" > /tmp/san.ext
      openssl x509 -req -in /tmp/rogue.csr -CA /tmp/rogue-ca.crt -CAkey /tmp/rogue-ca.key \
        -CAcreateserial -days 30 -extfile /tmp/san.ext -out /tmp/rogue.crt 2>/dev/null
      cp /tmp/rogue.crt apiserver.crt
      cp /tmp/rogue.key apiserver.key
    '
    docker exec "$CP" mv "$MDIR/kube-apiserver.yaml" /tmp/kube-apiserver.yaml
    sleep 5
    docker exec "$CP" mv /tmp/kube-apiserver.yaml "$MDIR/kube-apiserver.yaml"
    echo
    echo "The API server will come UP this time -- but kubectl will refuse to talk"
    echo "to it. Read the client-side error, not the server logs."
    ;;
  *)
    echo "usage: $0 <1|2|3>"; exit 1 ;;
esac
