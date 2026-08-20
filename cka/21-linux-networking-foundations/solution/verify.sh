#!/usr/bin/env bash
# CKA 21 verification. Run from the assignment directory, AFTER netns-lab.sh
# and BEFORE netns-clean.sh:
#
#   bash solution/verify.sh
#
# It runs its checks inside the node, since that is where everything lives.
NODE=${NODE:-devops-worker}
BR=v-net-0
SUBNET=192.168.15
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
n()  { docker exec "$NODE" "$@" 2>/dev/null; }

echo "== 0. Can we reach the node? =="
if n true; then ok "docker exec into $NODE works"; else
  no "cannot exec into $NODE -- set NODE=<container> if your cluster differs"
  echo; echo "== 0 passed, 1 failed =="; exit 1
fi

echo "== 1. The namespaces you built =="
for ns in red blue; do
  n ip netns list | grep -q "^${ns}" && ok "namespace $ns exists" \
                                     || no "namespace $ns missing -- run netns-lab.sh"
done

for pair in "red ${SUBNET}.1" "blue ${SUBNET}.2"; do
  set -- $pair
  n ip -n "$1" addr | grep -q "$2" && ok "  $1 has $2" || no "  $1 does not have $2"
done

echo "== 2. The bridge =="
n ip -br link show type bridge | grep -q "$BR" && ok "$BR exists" || no "$BR missing"
n ip addr show $BR | grep -q "${SUBNET}.5" && ok "  the bridge carries ${SUBNET}.5" \
                                           || no "  no address on the bridge -- the host cannot reach the namespaces"
c=$(n ip link show master $BR | grep -c "^[0-9]")
[ "${c:-0}" -ge 2 ] 2>/dev/null && ok "  $c interfaces are plugged into it" \
                                || no "  only ${c:-0} interface(s) on the bridge, expected 2"

echo "== 3. Connectivity through the bridge =="
if n ip netns exec red ping -c1 -W2 ${SUBNET}.2 >/dev/null 2>&1; then
  ok "red reaches blue"
else
  no "red cannot reach blue -- is $BR up?"
fi
if n ping -c1 -W2 ${SUBNET}.1 >/dev/null 2>&1; then
  ok "the node itself reaches red"
else
  no "the node cannot reach red"
fi

echo "== 4. The way out =="
n ip -n red route | grep -q "^default via ${SUBNET}.5" && ok "red has a default route via the bridge" \
                                                       || no "red has no default route"
n iptables -t nat -S POSTROUTING | grep -q "${SUBNET}.0/24 -j MASQUERADE" \
  && ok "a MASQUERADE rule exists for ${SUBNET}.0/24" \
  || no "no MASQUERADE rule -- replies could not come back"

echo "== 5. The way in =="
n iptables -t nat -S PREROUTING | grep -q "dport 8080 -j DNAT" \
  && ok "a DNAT rule forwards 8080 into the namespace" \
  || no "no DNAT rule on port 8080"

echo "== 6. The node's own Kubernetes networking =="
f=$(n cat /proc/sys/net/ipv4/ip_forward)
[ "$f" = "1" ] && ok "ip_forward is 1" || no "ip_forward is '${f:-?}' -- pods could not leave this node"

r=$(n ip route | grep -c "via.*dev eth0")
[ "${r:-0}" -ge 1 ] 2>/dev/null && ok "$r route(s) to other networks via eth0" \
                                || no "no routes to other nodes' pod CIDRs"

v=$(n ip -br link show type veth | grep -c .)
[ "${v:-0}" -ge 1 ] 2>/dev/null && ok "$v veth interface(s) on the node -- one per pod plus the lab's" \
                                || no "no veth interfaces found"

k=$(n iptables -t nat -S | grep -c KUBE)
[ "${k:-0}" -ge 1 ] 2>/dev/null && ok "$k kube-proxy NAT rules present" \
                                || no "no KUBE- rules -- is kube-proxy running?"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
