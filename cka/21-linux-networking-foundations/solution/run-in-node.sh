#!/usr/bin/env bash
# Copy a script into a kind node and run it there.
#
#   bash solution/run-in-node.sh netns-lab.sh
#   bash solution/run-in-node.sh netns-clean.sh
#   NODE=devops-control-plane bash solution/run-in-node.sh inspect-pod-network.sh
#
# Everything in this assignment happens INSIDE a node, because that is where
# the namespaces, bridges and iptables rules live. A kind node is an ordinary
# Linux host running privileged, so `ip netns` and `iptables` all work.
set -euo pipefail
NODE=${NODE:-devops-worker}
SCRIPT=${1:-}
shift || true
[ -n "$SCRIPT" ] || { echo "usage: $0 <script.sh> [args...]"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "${HERE}/${SCRIPT}" ] || { echo "no such script: ${HERE}/${SCRIPT}"; exit 1; }

docker cp "${HERE}/${SCRIPT}" "${NODE}:/tmp/${SCRIPT}"
docker exec "$NODE" chmod +x "/tmp/${SCRIPT}"
docker exec "$NODE" "/tmp/${SCRIPT}" "$@"
