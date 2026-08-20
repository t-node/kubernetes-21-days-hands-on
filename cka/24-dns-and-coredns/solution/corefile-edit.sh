#!/usr/bin/env bash
# Add or remove a `hosts` block in the CoreDNS Corefile, safely.
#
#   bash solution/corefile-edit.sh add        # fake internal.example -> 10.9.9.9
#   bash solution/corefile-edit.sh remove
#   bash solution/corefile-edit.sh show
#
# It backs the Corefile up to /tmp/corefile.backup on the first `add`, so a
# botched edit is always one `restore` away.
set -euo pipefail
BAK=${BAK:-/tmp/corefile.backup}
MARK="### cka24-hosts-block"

get() { kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'; }

put() {  # put <file>
  kubectl -n kube-system create configmap coredns --from-file=Corefile="$1" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "-- Corefile updated. The reload plugin picks it up within ~30s;"
  echo "   no restart is needed (24.3)."
}

case "${1:-show}" in
  show)
    get; echo ;;

  add)
    [ -f "$BAK" ] || { get > "$BAK"; echo "-- backed up the current Corefile to $BAK"; }
    TMP=$(mktemp)
    get > "$TMP"
    if grep -q "$MARK" "$TMP"; then
      echo "-- the block is already present"; rm -f "$TMP"; exit 0
    fi
    # Insert a hosts block just after the `ready` line, inside the server block.
    python - "$TMP" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
block = [
    "    " + mark,
    "    hosts {",
    "       10.9.9.9 internal.example",
    "       fallthrough",
    "    }",
]
try:
    i = next(i for i, l in enumerate(lines) if l.strip() == "ready")
except StopIteration:
    i = next(i for i, l in enumerate(lines) if l.strip().startswith("errors"))
lines[i+1:i+1] = block
open(path, "w", newline="\n").write("\n".join(lines))
print("-- inserted a hosts block after the 'ready' plugin")
PY
    put "$TMP"; rm -f "$TMP"
    echo
    echo "Test it in ~30s:"
    echo "   kubectl exec -n cka24 dnsutils -- dig +short internal.example"
    ;;

  remove)
    TMP=$(mktemp)
    get > "$TMP"
    python - "$TMP" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, skip = [], 0
for l in lines:
    if mark in l:
        skip = 5          # the marker plus the four lines of the hosts block
    if skip > 0:
        skip -= 1
        continue
    out.append(l)
open(path, "w", newline="\n").write("\n".join(out))
print("-- removed the hosts block")
PY
    put "$TMP"; rm -f "$TMP"
    ;;

  restore)
    [ -f "$BAK" ] || { echo "no backup at $BAK"; exit 1; }
    put "$BAK"
    echo "-- restored from $BAK"
    ;;

  *)
    echo "usage: $0 <show|add|remove|restore>"; exit 1 ;;
esac
