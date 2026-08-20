#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Everything CNI on this machine, in one pass.
#
#   bash solution/run-in-node.sh cni-explore.sh
set -uo pipefail
say() { echo; echo "=== $*"; }

say "1. the plugin binaries (/opt/cni/bin)"
ls -1 /opt/cni/bin/ 2>/dev/null || echo "(missing -- no CNI plugins installed)"

say "2. the configuration (/etc/cni/net.d)"
ls -la /etc/cni/net.d/ 2>/dev/null || echo "(missing -- this node would be NotReady)"
echo
echo "-- the FIRST file alphabetically is the one that is used:"
CONF=$(ls -1 /etc/cni/net.d/ 2>/dev/null | head -1)
echo "   ${CONF:-none}"
if [ -n "${CONF:-}" ]; then
  echo
  cat "/etc/cni/net.d/${CONF}"
fi

say "3. the plugin chain in that file"
if [ -n "${CONF:-}" ]; then
  grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "/etc/cni/net.d/${CONF}" \
    | sed 's/.*: *"/   /; s/"$//' | nl
  echo
  echo "-- each of those is a separate binary in /opt/cni/bin, run in order (22.4)"
fi

say "4. IPAM state -- the entire address database (22.5)"
for d in /var/lib/cni/networks/*/; do
  [ -d "$d" ] || continue
  echo "network: $(basename "$d")"
  ls -1 "$d" | grep -E '^[0-9]' | while read -r ip; do
    printf "   %-16s held by %s\n" "$ip" "$(head -c 20 "$d/$ip" 2>/dev/null)"
  done
  echo "   last_reserved: $(cat "$d/last_reserved_ip.0" 2>/dev/null || echo n/a)"
done
[ -d /var/lib/cni/networks ] || echo "(no host-local state -- this CNI manages IPAM elsewhere)"

say "5. who configured the runtime to find these (22.6)"
grep -n -A4 -i 'cni' /etc/containerd/config.toml 2>/dev/null | head -20 \
  || echo "(no cni section in containerd config -- defaults are in use)"

say "6. routed or overlay? (22.7)"
if ip -d link show type vxlan 2>/dev/null | grep -q vxlan; then
  echo "VXLAN interfaces present -- this is an OVERLAY:"
  ip -d link show type vxlan | head
elif ip link show tunl0 >/dev/null 2>&1; then
  echo "tunl0 present -- IPIP encapsulation may be in use"
  ip -d link show tunl0 | head -3
else
  echo "no vxlan and no tunl0 -- this cluster is ROUTED"
fi
echo
echo "-- the pod routes:"
ip route | grep -E '10\.24[0-9]|192\.168' || ip route

say "7. MTU -- worth checking on an overlay"
ip -br link | awk '{print $1, $NF}' | head -8
echo "(a pod interface with MTU 1450 or 1400 means encapsulation overhead)"

say "8. this node's identity (22.8)"
echo "hostname:    $(hostname)"
echo "machine-id:  $(cat /etc/machine-id 2>/dev/null)"
echo "eth0 MAC:    $(cat /sys/class/net/eth0/address 2>/dev/null)"

say "9. control-plane ports listening here (22.8)"
ss -tlnp 2>/dev/null | grep -E '6443|10250|10257|10259|2379|2380' \
  || echo "(none of the control-plane ports -- this is a worker)"
