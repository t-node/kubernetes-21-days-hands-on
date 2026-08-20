#!/usr/bin/env bash
# Build the CKA 03 demonstration image and load it into the kind cluster.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${1:-devops}"

echo "==> building ubuntu-sleeper:1.0"
docker build -t ubuntu-sleeper:1.0 "${HERE}/ubuntu-sleeper"

echo "==> loading into kind cluster ${CLUSTER}"
kind load docker-image ubuntu-sleeper:1.0 --name "${CLUSTER}"

cat <<'EOF'

Done. Verify the Docker behaviour first:

  time docker run --rm ubuntu-sleeper:1.0        # ~5s   -> sleep 5   (CMD)
  time docker run --rm ubuntu-sleeper:1.0 10     # ~10s  -> sleep 10  (CMD replaced)

Then the Kubernetes truth table:

  kubectl apply -f 01-four-combinations.yaml

REMEMBER: imagePullPolicy: IfNotPresent, or the kubelet goes to Docker Hub
looking for an image that only exists on your machine.
EOF
