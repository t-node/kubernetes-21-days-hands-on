#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Build, by hand, the network a CNI plugin builds.
#
#   bash solution/run-in-node.sh netns-lab.sh
#
# Six steps, each printing what it did so you can follow along:
#   1. two empty network namespaces
#   2. a veth pair joining them directly
#   3. throw that away; build a bridge and connect both to it
#   4. give the bridge an address so the HOST joins their network
#   5. a default route + MASQUERADE so they can reach the outside
#   6. a DNAT rule so the outside can reach one of them
set -uo pipefail

BR=v-net-0
SUBNET=192.168.15
say() { echo; echo "=== $*"; }

say "0. cleaning up anything from a previous run"
for ns in red blue; do ip netns del $ns 2>/dev/null; done
ip link del $BR 2>/dev/null
iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -j MASQUERADE 2>/dev/null
iptables -t nat -D PREROUTING -p tcp --dport 8080 -j DNAT --to-destination ${SUBNET}.2:80 2>/dev/null
echo "done"

say "1. two network namespaces"
ip netns add red
ip netns add blue
ip netns list
echo "-- what does 'red' see? (only loopback: it has nothing)"
ip -n red link

say "2. a veth pair joining them directly"
ip link add veth-red type veth peer name veth-blue
ip link set veth-red netns red
ip link set veth-blue netns blue
ip -n red  addr add ${SUBNET}.1/24 dev veth-red
ip -n blue addr add ${SUBNET}.2/24 dev veth-blue
ip -n red  link set veth-red up
ip -n blue link set veth-blue up
ip -n red link set lo up
ip -n blue link set lo up
echo "-- red can now reach blue over the virtual cable:"
ip netns exec red ping -c2 -W1 ${SUBNET}.2 | tail -3
echo "-- and red's ARP table has learned about its neighbour:"
ip netns exec red ip neigh
echo "-- while the HOST knows nothing about either of them:"
ip neigh | grep -c "${SUBNET}" || echo "0 entries -- as expected"

say "3. a bridge instead, so more than two can join"
ip link del veth-red            # deleting one end removes the pair
ip link add $BR type bridge
ip link set dev $BR up
for ns in red blue; do
  ip link add veth-$ns type veth peer name veth-$ns-br
  ip link set veth-$ns netns $ns
  ip link set veth-$ns-br master $BR
  ip link set veth-$ns-br up
  ip -n $ns link set veth-$ns up
done
ip -n red  addr add ${SUBNET}.1/24 dev veth-red
ip -n blue addr add ${SUBNET}.2/24 dev veth-blue
echo "-- what is plugged into the bridge:"
ip link show master $BR
echo "-- red reaches blue THROUGH the bridge now:"
ip netns exec red ping -c2 -W1 ${SUBNET}.2 | tail -3

say "4. give the bridge an address -- the host joins their network"
ip addr add ${SUBNET}.5/24 dev $BR
echo "-- from the host into the namespace:"
ping -c2 -W1 ${SUBNET}.1 | tail -3

say "5. a way out: default route + MASQUERADE"
echo "-- before: red has no route off its own network"
ip -n red route
ip netns exec red ping -c1 -W1 8.8.8.8 2>&1 | tail -1
ip -n red  route add default via ${SUBNET}.5
ip -n blue route add default via ${SUBNET}.5
iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -j MASQUERADE
echo "-- after: a default gateway and source NAT"
ip -n red route
echo "-- ip_forward on this host:"
cat /proc/sys/net/ipv4/ip_forward
echo "-- red can now reach the node's own address (proof the path works):"
NODEIP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
ip netns exec red ping -c2 -W1 "$NODEIP" | tail -3

say "6. a way in: DNAT, which is all a NodePort is"
ip netns exec blue sh -c 'nohup nc -lk -p 80 -e /bin/echo "hello from the blue namespace" >/dev/null 2>&1 &' || true
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination ${SUBNET}.2:80
echo "-- the rule, as iptables sees it:"
iptables -t nat -L PREROUTING -n --line-numbers | head -6

say "DONE"
echo "Namespaces:      ip netns list"
echo "Bridge members:  ip link show master $BR"
echo "NAT rules:       iptables -t nat -L -n | head -30"
echo "Tear down with:  bash solution/run-in-node.sh netns-clean.sh"
