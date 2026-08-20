#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Show the SAME primitives, as Kubernetes built them.
#
#   bash solution/run-in-node.sh inspect-pod-network.sh
#
# Everything printed here maps onto something netns-lab.sh created by hand.
set -uo pipefail
say() { echo; echo "=== $*"; }

say "1. the node's own interfaces and routes"
ip -br addr
echo
ip route

say "2. ip_forward (21.3) -- must be 1 on every Kubernetes node"
cat /proc/sys/net/ipv4/ip_forward

say "3. bridges on this node"
ip -br link show type bridge || echo "(none -- this CNI may not use a bridge)"

say "4. veth interfaces on the node side"
echo "one end of each pair; the other end is inside a pod"
ip -br link show type veth | head -20
echo "..."
ip -br link show type veth | wc -l
echo "veth interfaces total"

say "5. a real pod's network namespace"
CID=$(crictl ps -q 2>/dev/null | head -1)
if [ -n "$CID" ]; then
  PID=$(crictl inspect "$CID" 2>/dev/null | grep -m1 '"pid"' | tr -dc '0-9')
  echo "container $CID runs as host PID $PID"
  echo "-- its network namespace, entered with nsenter:"
  nsenter -t "$PID" -n ip -br addr
  echo "-- its routes:"
  nsenter -t "$PID" -n ip route
  echo "-- its /etc/resolv.conf comes from the kubelet, not from this host:"
  crictl exec "$CID" cat /etc/resolv.conf 2>/dev/null || echo "   (no shell in that image)"
  echo
  echo "NOTE the pod's default route points at the BRIDGE address -- exactly"
  echo "     what you configured by hand in step 5 of netns-lab.sh."
else
  echo "no running containers found via crictl"
fi

say "6. the veth pair, matched up"
echo "each pod-side interface records the index of its node-side peer:"
if [ -n "${PID:-}" ]; then
  nsenter -t "$PID" -n ip -o link show eth0 2>/dev/null | head -2
  IDX=$(nsenter -t "$PID" -n ip -o link show eth0 2>/dev/null | sed -n 's/.*eth0@if\([0-9]*\).*/\1/p')
  if [ -n "$IDX" ]; then
    echo "-- pod's eth0 is paired with node interface index ${IDX}:"
    ip -o link | awk -v i="$IDX" -F': ' '$1==i {print}'
  fi
fi

say "7. the iptables rules kube-proxy wrote (21.6)"
echo "-- Service chains:"
iptables -t nat -L PREROUTING -n | head -8
echo
echo "-- how many rules kube-proxy maintains here:"
iptables -t nat -S 2>/dev/null | grep -c KUBE
echo
echo "-- one Service, resolved to its endpoints:"
iptables -t nat -S 2>/dev/null | grep -m6 "KUBE-SVC" || true

say "DONE -- compare every section above with what netns-lab.sh built by hand"
