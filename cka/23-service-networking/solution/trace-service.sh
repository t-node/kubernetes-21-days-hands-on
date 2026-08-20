#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Walk the iptables chains for one Service.
#
#   bash solution/run-in-node.sh trace-service.sh <clusterIP> [port]
#
# It follows KUBE-SERVICES -> KUBE-SVC-xxx -> KUBE-SEP-xxx, printing each layer
# and the arithmetic behind the probabilities (23.5).
set -uo pipefail
IP=${1:-}
PORT=${2:-80}
[ -n "$IP" ] || { echo "usage: $0 <clusterIP> [port]"; exit 1; }

say() { echo; echo "=== $*"; }

say "0. does this address exist anywhere on the node? (23.1)"
if ip addr | grep -q " ${IP}/"; then
  echo "   FOUND on an interface -- unexpected for a ClusterIP"
else
  echo "   not on any interface"
fi
echo "   ip route get ${IP}:"
ip route get "$IP" 2>&1 | head -2

say "1. KUBE-SERVICES -- the entry point"
SVC_CHAIN=$(iptables -t nat -S KUBE-SERVICES 2>/dev/null \
            | grep -- "-d ${IP}/32" | grep -- "--dport ${PORT}" \
            | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1)
iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep -- "-d ${IP}/32" | sed 's/^/   /'
if [ -z "$SVC_CHAIN" ]; then
  echo
  echo "   no KUBE-SVC chain for ${IP}:${PORT}."
  echo "   Either the Service has no endpoints (look for a REJECT rule above),"
  echo "   or kube-proxy has not written rules for it yet."
  iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep -- "$IP" | grep -i reject | sed 's/^/   /'
  exit 0
fi
echo "   -> ${SVC_CHAIN}"

say "2. ${SVC_CHAIN} -- one rule per endpoint"
iptables -t nat -S "$SVC_CHAIN" 2>/dev/null | sed 's/^/   /'

SEPS=$(iptables -t nat -S "$SVC_CHAIN" 2>/dev/null | grep -o 'KUBE-SEP-[A-Z0-9]*' | sort -u)
N=$(echo "$SEPS" | grep -c .)
echo
echo "   ${N} endpoint chain(s). Expected probabilities for ${N} endpoints:"
i=1
while [ "$i" -le "$N" ]; do
  remaining=$(( N - i + 1 ))
  awk -v r="$remaining" -v i="$i" 'BEGIN{printf "     endpoint %d: 1/%d = %.4f\n", i, r, 1/r}'
  i=$(( i + 1 ))
done
echo "   (the last has no probability at all -- it is the fallthrough)"

say "3. the endpoint chains -- where DNAT actually happens"
for sep in $SEPS; do
  echo "   ${sep}:"
  iptables -t nat -S "$sep" 2>/dev/null | grep DNAT | sed 's/^/      /'
done

say "4. active translations for this Service (conntrack, 23.5)"
if command -v conntrack >/dev/null 2>&1; then
  conntrack -L 2>/dev/null | grep "$IP" | head -5 || echo "   (no active flows)"
else
  echo "   conntrack not installed on this node"
fi

say "5. is this Service reached from the node itself? (the OUTPUT hook)"
iptables -t nat -S OUTPUT | grep KUBE-SERVICES | sed 's/^/   /'
iptables -t nat -S PREROUTING | grep KUBE-SERVICES | sed 's/^/   /'
echo "   both hooks present means pods on this node and traffic from elsewhere"
echo "   are handled by the same chain"
