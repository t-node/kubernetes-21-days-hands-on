#!/usr/bin/env bash
# Nuke and recreate the course cluster from scratch, then reload the app images.
# Useful when an experiment leaves the cluster in a weird state -- which will
# happen, and is fine. Recreating takes about 60-90 seconds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kind delete cluster --name devops || true
kind create cluster --config "${HERE}/kind-config.yaml"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

if docker image inspect devboard-backend:1.0 >/dev/null 2>&1; then
  echo "==> reloading DevBoard images"
  "${HERE}/../app/build-images.sh" 1.0 devops
fi

kubectl get nodes -o wide
