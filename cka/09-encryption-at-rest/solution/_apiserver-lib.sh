#!/usr/bin/env bash
# Shared helpers for the CKA 09 scripts. Sourced, not run.
#
# Everything here is something you would do by hand in the exam. Read it once so
# the scripts are not magic.

CP=${CP:-devops-control-plane}
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
ENC_DIR=/etc/kubernetes/enc
ENC_FILE=${ENC_DIR}/enc.yaml

backup_manifest() {
  docker exec "$CP" test -f /root/apiserver.backup.yaml 2>/dev/null || {
    echo "-- first-time backup -> /root/apiserver.backup.yaml on $CP"
    docker exec "$CP" cp "$MANIFEST" /root/apiserver.backup.yaml
  }
}

wait_ready() {
  echo -n "-- waiting for the API server"
  local i
  for i in $(seq 1 120); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      echo " ... ready after ${i}s"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo
  echo "!! API server did not return in 120s."
  echo "!! Logs:    docker exec $CP sh -c 'crictl logs \$(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20'"
  echo "!! Restore: docker exec $CP cp /root/apiserver.backup.yaml $MANIFEST"
  return 1
}

# Restart the API server without changing its manifest, by moving the manifest
# out of the watched directory and back. The kubelet reacts to both moves.
restart_apiserver() {
  echo "-- restarting the API server (manifest out and back)"
  docker exec "$CP" mv "$MANIFEST" /tmp/kube-apiserver.yaml
  local i
  for i in $(seq 1 30); do
    if ! docker exec "$CP" sh -c "crictl ps --name kube-apiserver -q 2>/dev/null | grep -q ." ; then
      break
    fi
    sleep 1
  done
  docker exec "$CP" mv /tmp/kube-apiserver.yaml "$MANIFEST"
  wait_ready
}

# Read the on-node encryption config to stdout.
read_enc() { docker exec "$CP" cat "$ENC_FILE"; }

# Write stdin to the on-node encryption config, mode 600.
write_enc() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  docker exec "$CP" mkdir -p "$ENC_DIR"
  docker cp "$tmp" "$CP:$ENC_FILE"
  docker exec "$CP" chmod 600 "$ENC_FILE"
  rm -f "$tmp"
}

etcd_cmd() {
  kubectl -n kube-system exec "etcd-${CP}" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key "$@"
}
