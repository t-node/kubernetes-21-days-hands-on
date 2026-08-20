#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Remove everything netns-lab.sh created.
#
#   bash solution/run-in-node.sh netns-clean.sh
#
# It touches ONLY the objects named below. Kubernetes' own namespaces, bridge
# and iptables rules are left alone.
set -uo pipefail
BR=v-net-0
SUBNET=192.168.15

echo "-- removing namespaces (this also removes their veth ends)"
for ns in red blue; do ip netns del $ns 2>/dev/null && echo "   deleted $ns"; done

echo "-- removing the bridge"
ip link del $BR 2>/dev/null && echo "   deleted $BR"

echo "-- removing leftover veth ends, if any"
for l in veth-red-br veth-blue-br; do ip link del $l 2>/dev/null && echo "   deleted $l"; done

echo "-- removing NAT rules"
iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -j MASQUERADE 2>/dev/null && echo "   removed MASQUERADE"
iptables -t nat -D PREROUTING -p tcp --dport 8080 -j DNAT --to-destination ${SUBNET}.2:80 2>/dev/null && echo "   removed DNAT"

echo
echo "-- what is left (should be only Kubernetes' own):"
ip netns list 2>/dev/null | head
ip -br link show type bridge 2>/dev/null
