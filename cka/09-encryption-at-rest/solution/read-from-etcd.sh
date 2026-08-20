#!/usr/bin/env bash
# Show how a Secret is actually stored in etcd.
#
#   bash solution/read-from-etcd.sh <namespace> <secret-name> [needle]
#
# With a needle (a plaintext value you expect NOT to find), it also reports
# whether that string is present in the raw bytes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_apiserver-lib.sh"

NS=${1:-default}
NAME=${2:-}
NEEDLE=${3:-}
[ -n "$NAME" ] || { echo "usage: $0 <namespace> <secret-name> [plaintext-needle]"; exit 1; }

KEY="/registry/secrets/${NS}/${NAME}"
echo "== raw bytes at ${KEY}"
etcd_cmd get "$KEY" | od -c | head -20

echo
echo "== envelope"
if etcd_cmd get "$KEY" | grep -a -o 'k8s:enc:[a-z0-9]*:v[0-9]*:[a-z0-9]*:' | head -1; then
  echo "   ^ encrypted: provider and key name are in that prefix"
else
  echo "   no k8s:enc: prefix -- this record is stored in PLAINTEXT"
fi

if [ -n "$NEEDLE" ]; then
  echo
  n=$(etcd_cmd get "$KEY" | grep -a -c "$NEEDLE" || true)
  if [ "${n:-0}" -gt 0 ]; then
    echo "== '${NEEDLE}' IS present in the raw bytes -- not encrypted"
  else
    echo "== '${NEEDLE}' is NOT present in the raw bytes"
  fi
fi
