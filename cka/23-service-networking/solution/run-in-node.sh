#!/usr/bin/env bash
# Copy a script into a kind node and run it there. Same helper as CKA 21/22.
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
