#!/usr/bin/env bash
# Take an etcd snapshot from the kubeadm static pod, verify it, and copy it off
# the node.
#
#   bash etcd-snapshot.sh
#
# `snapshot save` talks to a LIVE etcd, so it always needs the endpoint and all
# three certificates. `snapshot status` and `snapshot restore` do not -- they
# only read a file.
set -euo pipefail
NODE="${NODE:-devops-control-plane}"
POD="${POD:-etcd-${NODE}}"
OUT="${1:-/tmp/etcd-snapshot.db}"

PKI=/etc/kubernetes/pki/etcd

echo "==> saving snapshot inside ${POD}"
kubectl -n kube-system exec "${POD}" -- sh -c "
  ETCDCTL_API=3 etcdctl snapshot save /var/lib/etcd/snapshot.db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=${PKI}/ca.crt \
    --cert=${PKI}/server.crt \
    --key=${PKI}/server.key
"

echo
echo "==> verifying (etcdutl on etcd 3.5+; falling back to etcdctl)"
kubectl -n kube-system exec "${POD}" -- \
  etcdutl snapshot status /var/lib/etcd/snapshot.db --write-out=table 2>/dev/null \
|| kubectl -n kube-system exec "${POD}" -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot status /var/lib/etcd/snapshot.db --write-out=table"

echo
echo "==> copying off the node (a backup ON the thing you are backing up is not a backup)"
docker cp "${NODE}:/var/lib/etcd/snapshot.db" "${OUT}"
ls -lh "${OUT}"

cat <<EOF

Snapshot at ${OUT} and at ${NODE}:/var/lib/etcd/snapshot.db

Check TOTAL KEYS above -- a snapshot with a handful of keys is a snapshot of
nothing. Restore with:

  bash etcd-restore.sh
EOF
