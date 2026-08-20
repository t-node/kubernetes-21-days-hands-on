#!/usr/bin/env bash
# Build the DevBoard images and load them into the kind cluster.
#
#   ./build-images.sh              # :1.0 into kind cluster "devops"
#   ./build-images.sh 2.0          # :2.0 (Day 05 / Day 08 rolling updates)
#   ./build-images.sh 1.0 mykind   # a differently named kind cluster
#
# Uses app/dockerfiles/*.Dockerfile (public bases) rather than the upstream
# Dockerfiles, which need Docker Hardened Image entitlements.
set -euo pipefail

VERSION="${1:-1.0}"
CLUSTER="${2:-devops}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/devboard"

if [ ! -d "${SRC}" ]; then
  echo "==> app source missing; fetching it"
  "${HERE}/get-devboard.sh"
fi

echo "==> building devboard-backend:${VERSION}  (Go + Gin)"
docker build \
  --build-arg "APP_VERSION=${VERSION}" \
  -f "${HERE}/dockerfiles/backend.Dockerfile" \
  -t "devboard-backend:${VERSION}" \
  "${SRC}/backend"

echo "==> building devboard-frontend:${VERSION}  (React + Vite)"
docker build \
  -f "${HERE}/dockerfiles/frontend.Dockerfile" \
  -t "devboard-frontend:${VERSION}" \
  "${SRC}/frontend"

echo "==> loading images into kind cluster '${CLUSTER}'"
kind load docker-image "devboard-backend:${VERSION}"  --name "${CLUSTER}"
kind load docker-image "devboard-frontend:${VERSION}" --name "${CLUSTER}"

cat <<EOF

Done. Present on every kind node now:
  devboard-backend:${VERSION}     listens on :8080  (PORT)
  devboard-frontend:${VERSION}    listens on :4173  (vite preview)

TWO THINGS TO REMEMBER:

1. Every Deployment using these MUST set
       imagePullPolicy: IfNotPresent
   or the kubelet goes to Docker Hub and you get ImagePullBackOff.

2. The frontend image proxies /api -> http://backend:8080
   so your backend Service MUST be named 'backend' on port 8080,
   unless you override /app/vite.config.js from a ConfigMap (Day 09).
EOF
