#!/usr/bin/env bash
# Undo anything break.sh did and wait for the control plane to come back.
#
#   bash solution/restore.sh
set -euo pipefail
CP=${CP:-devops-control-plane}
MDIR=/etc/kubernetes/manifests

docker exec "$CP" test -d /root/manifests.backup || {
  echo "no /root/manifests.backup on $CP -- nothing to restore from"; exit 1; }

echo "==> restoring the static pod manifests"
docker exec "$CP" sh -c "cp /root/manifests.backup/*.yaml $MDIR/"

if docker exec "$CP" test -f /root/apiserver.crt.orig; then
  echo "==> restoring the original API server serving certificate"
  docker exec "$CP" sh -c '
    cp /root/apiserver.crt.orig /etc/kubernetes/pki/apiserver.crt
    cp /root/apiserver.key.orig /etc/kubernetes/pki/apiserver.key
    rm -f /root/apiserver.crt.orig /root/apiserver.key.orig'
  # force a restart so the new certificate is actually read
  docker exec "$CP" mv "$MDIR/kube-apiserver.yaml" /tmp/kube-apiserver.yaml
  sleep 5
  docker exec "$CP" mv /tmp/kube-apiserver.yaml "$MDIR/kube-apiserver.yaml"
fi

echo -n "==> waiting for the API server"
for i in $(seq 1 120); do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then echo " ... back after ${i}s"; exit 0; fi
  echo -n "."
  sleep 1
done
echo
echo "!! still down after 120s. Look at:"
echo "   docker exec $CP crictl ps -a | grep -E 'apiserver|etcd'"
echo "   docker exec $CP sh -c 'crictl logs \$(crictl ps -a --name etcd -q | head -1) 2>&1 | tail'"
exit 1
