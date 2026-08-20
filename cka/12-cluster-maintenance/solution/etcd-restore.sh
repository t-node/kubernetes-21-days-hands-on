#!/usr/bin/env bash
# Restore etcd from a snapshot on a kubeadm (and kind) cluster.
#
#   bash etcd-restore.sh
#
# WHAT THIS DOES -- the four steps from section 6.8:
#   1. restore the snapshot into a NEW data directory
#   2. move it to /var/lib/etcd-from-backup on the node
#   3. repoint the hostPath VOLUME in /etc/kubernetes/manifests/etcd.yaml
#   4. let the kubelet recreate the etcd static pod
#
# WHY IT IS SAFE: the original /var/lib/etcd is never touched. If this goes
# wrong, put the hostPath back to /var/lib/etcd and you are exactly where you
# started. See the ROLLBACK section at the bottom.
#
# The API server WILL be unavailable for a minute or two. That is expected.
set -euo pipefail
NODE="${NODE:-devops-control-plane}"
POD="${POD:-etcd-${NODE}}"
SNAP_IN_POD="${SNAP_IN_POD:-/var/lib/etcd/snapshot.db}"
NEWDIR=/var/lib/etcd-from-backup

echo "==> 0. sanity: does the snapshot exist and have data?"
kubectl -n kube-system exec "${POD}" -- \
  etcdutl snapshot status "${SNAP_IN_POD}" --write-out=table 2>/dev/null \
|| kubectl -n kube-system exec "${POD}" -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot status ${SNAP_IN_POD} --write-out=table"

echo
echo "==> 1. restoring into a temporary directory inside the mounted volume"
# /var/lib/etcd is the only writable hostPath the etcd container has, so restore
# into a subdirectory of it, then move it out on the node.
kubectl -n kube-system exec "${POD}" -- rm -rf /var/lib/etcd/_restore || true
kubectl -n kube-system exec "${POD}" -- sh -c "
  etcdutl snapshot restore ${SNAP_IN_POD} --data-dir=/var/lib/etcd/_restore \
  2>/dev/null \
  || ETCDCTL_API=3 etcdctl snapshot restore ${SNAP_IN_POD} --data-dir=/var/lib/etcd/_restore
"

echo
echo "==> 2. moving it to ${NEWDIR} on the node"
docker exec "${NODE}" sh -c "rm -rf ${NEWDIR} && mv /var/lib/etcd/_restore ${NEWDIR} && ls -la ${NEWDIR}"

echo
echo "==> 3. repointing the hostPath volume in etcd.yaml"
docker exec "${NODE}" sh -c "
  cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
  sed -i 's|path: /var/lib/etcd\$|path: ${NEWDIR}|' /etc/kubernetes/manifests/etcd.yaml
  grep -A2 'name: etcd-data' /etc/kubernetes/manifests/etcd.yaml
"

echo
echo "==> 4. the kubelet is recreating the etcd static pod. Waiting for the API server..."
for i in $(seq 1 40); do
  if kubectl get ns >/dev/null 2>&1; then
    echo "    API server is back after ~$((i*5))s"
    kubectl get ns
    exit 0
  fi
  printf '.'
  sleep 5
done

cat <<EOF

The API server did not return within ~200s.

ROLLBACK -- the original data is untouched:

  docker exec ${NODE} cp /etc/kubernetes/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml

Then wait ~60s. If that also fails, rebuild in 90 seconds:

  bash cluster/recreate-cluster.sh

Diagnose from the node (kubectl will not work while the API server is down):

  docker exec ${NODE} sh -c 'crictl ps -a --name etcd'
  docker exec ${NODE} sh -c 'CID=\$(crictl ps -a --name etcd -q | head -1); crictl logs \$CID 2>&1 | tail -20'
EOF
exit 1
