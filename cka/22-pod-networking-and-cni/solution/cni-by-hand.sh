#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Invoke a CNI plugin the way containerd does.
#
#   bash solution/run-in-node.sh cni-by-hand.sh add
#   bash solution/run-in-node.sh cni-by-hand.sh del
#
# This is the whole of CNI: a network namespace, a JSON config on stdin, five
# environment variables, and a binary. No daemon, no API, no Kubernetes.
set -uo pipefail

NS=cnidemo
NETNS=/var/run/netns/${NS}
CONF=/tmp/cni-demo.json
SUBNET=10.99.0.0/24
ACTION=${1:-add}

# kind ships a subset of the reference plugins. Prefer bridge; fall back to ptp.
PLUGIN=""
for p in bridge ptp; do
  [ -x "/opt/cni/bin/$p" ] && { PLUGIN=$p; break; }
done
[ -n "$PLUGIN" ] || { echo "neither bridge nor ptp found in /opt/cni/bin:"; ls /opt/cni/bin; exit 1; }
[ -x /opt/cni/bin/host-local ] || { echo "host-local IPAM plugin missing"; exit 1; }

cat > "$CONF" <<EOF
{
  "cniVersion": "0.4.0",
  "name": "cni-demo",
  "type": "${PLUGIN}",
  "bridge": "cni-demo0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "${SUBNET}",
    "routes": [ { "dst": "0.0.0.0/0" } ]
  }
}
EOF

run_plugin() {   # run_plugin <ADD|DEL>
  CNI_COMMAND="$1" \
  CNI_CONTAINERID="cni-demo-container" \
  CNI_NETNS="$NETNS" \
  CNI_IFNAME="eth0" \
  CNI_PATH="/opt/cni/bin" \
    "/opt/cni/bin/${PLUGIN}" < "$CONF"
}

case "$ACTION" in
  add)
    echo "=== plugin selected: ${PLUGIN}"
    echo "=== configuration handed to it on stdin:"
    cat "$CONF"

    echo
    echo "=== 1. the RUNTIME's job: create the network namespace (22.2)"
    ip netns del "$NS" 2>/dev/null
    ip netns add "$NS"
    echo "-- before the plugin runs, the namespace has nothing:"
    ip -n "$NS" addr

    echo
    echo "=== 2. the PLUGIN's job: invoke it with CNI_COMMAND=ADD"
    echo "--- plugin output (this is the CNI Result format):"
    run_plugin ADD
    RC=$?
    echo "--- exit code: $RC"

    echo
    echo "=== 3. what it did inside the namespace"
    ip -n "$NS" addr
    echo "-- routes:"
    ip -n "$NS" route

    echo
    echo "=== 4. what it did on the host"
    echo "-- the bridge it created (if this plugin uses one):"
    ip -br link show type bridge | grep cni-demo || echo "   (ptp uses a veth pair with no bridge)"
    echo "-- the veth end on this side:"
    ip -br link | grep -E 'veth' | tail -3
    echo "-- the MASQUERADE rule from ipMasq: true (21.6):"
    iptables -t nat -S | grep -i "10.99" || echo "   (none found)"

    echo
    echo "=== 5. IPAM wrote its state to disk (22.5)"
    ls -1 /var/lib/cni/networks/cni-demo/ 2>/dev/null | sed 's/^/   /' \
      || echo "   (no state directory yet)"
    for f in /var/lib/cni/networks/cni-demo/10.*; do
      [ -f "$f" ] && echo "   $(basename "$f") -> $(cat "$f")"
    done

    echo
    echo "=== 6. it works"
    GW=$(ip -n "$NS" route | awk '/default/{print $3}')
    echo "-- pinging the gateway ${GW} from inside the namespace:"
    ip netns exec "$NS" ping -c2 -W1 "$GW" 2>&1 | tail -3

    echo
    echo "Tear it down with:  bash solution/run-in-node.sh cni-by-hand.sh del"
    ;;

  del)
    echo "=== invoking the plugin with CNI_COMMAND=DEL"
    if [ -e "$NETNS" ]; then
      run_plugin DEL
      echo "--- exit code: $?"
    else
      echo "(namespace already gone; the plugin still releases the IPAM lease)"
      CNI_COMMAND=DEL CNI_CONTAINERID="cni-demo-container" CNI_NETNS="" \
      CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin "/opt/cni/bin/${PLUGIN}" < "$CONF"
    fi
    ip netns del "$NS" 2>/dev/null
    ip link del cni-demo0 2>/dev/null
    rm -f "$CONF"
    echo
    echo "-- IPAM state after DEL (the address should be released):"
    ls -1 /var/lib/cni/networks/cni-demo/ 2>/dev/null | sed 's/^/   /' || echo "   (gone)"
    echo
    echo "NOTE: DEL is what the runtime calls when a pod is deleted. A plugin"
    echo "      that fails DEL leaks both the interface and the IP address --"
    echo "      which is exactly how a node runs out of pod IPs (22.5)."
    ;;

  *)
    echo "usage: $0 <add|del>"; exit 1 ;;
esac
