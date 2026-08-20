#!/usr/bin/env bash
# CKA 22 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Checks the CNI installation on a node and that it matches what the cluster
# thinks is true. Safe to run at any point; it creates one short-lived pod.
NODE=${NODE:-devops-worker}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
n()  { docker exec "$NODE" "$@" 2>/dev/null; }

echo "== 0. Reachability =="
n true && ok "docker exec into $NODE works" || {
  no "cannot exec into $NODE -- set NODE=<container>"; echo; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== 1. Plugin binaries and configuration (22.4) =="
b=$(n ls /opt/cni/bin | grep -c .)
[ "${b:-0}" -ge 1 ] 2>/dev/null && ok "$b plugin binaries in /opt/cni/bin" \
                                || no "/opt/cni/bin is empty or missing"
n ls /opt/cni/bin | grep -q host-local && ok "  host-local IPAM plugin present" \
                                       || no "  host-local missing -- IPAM would fail"

c=$(n ls /etc/cni/net.d | grep -c .)
[ "${c:-0}" -ge 1 ] 2>/dev/null && ok "$c configuration file(s) in /etc/cni/net.d" \
                                || no "/etc/cni/net.d is empty -- this node should be NotReady"

CONF=$(n sh -c 'ls -1 /etc/cni/net.d | head -1')
[ -n "$CONF" ] && ok "  the file in effect is $CONF (first alphabetically)" \
               || no "  no config file to read"

if [ -n "$CONF" ]; then
  types=$(n sh -c "grep -o '\"type\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' /etc/cni/net.d/$CONF" \
          | sed 's/.*: *"//; s/"$//' | tr '\n' ' ')
  [ -n "$types" ] && ok "  plugin chain: $types" || no "  could not read the plugin chain"
fi

echo "== 2. IPAM state matches the pods on this node (22.5) =="
ips=$(n sh -c 'ls /var/lib/cni/networks/*/ 2>/dev/null | grep -cE "^[0-9]+\."')
pods=$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" \
        -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null \
        | grep -c '^10\.' )
if [ "${ips:-0}" -ge 1 ] 2>/dev/null; then
  ok "$ips address(es) recorded in /var/lib/cni/networks"
  echo "        (pods scheduled here with a pod IP: ${pods:-0})"
  if [ "${ips:-0}" -gt $(( ${pods:-0} + 3 )) ]; then
    no "  many more IPAM entries than pods -- possible leaked allocations (22.5)"
  else
    ok "  the counts are consistent"
  fi
else
  echo "  NOTE  no host-local state directory -- this CNI manages IPAM elsewhere"
fi

echo "== 3. The node's routing (22.1, requirement 3) =="
f=$(n cat /proc/sys/net/ipv4/ip_forward)
[ "$f" = "1" ] && ok "ip_forward is 1" || no "ip_forward is '${f:-?}'"

others=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -vc "^$NODE$")
routes=$(n sh -c "ip route | grep -c 'via.*dev eth0'")
[ "${routes:-0}" -ge 1 ] 2>/dev/null && ok "$routes via-route(s) present; cluster has ${others:-?} other node(s)" \
                                     || no "no routes to other nodes' pod CIDRs"

echo "== 4. Routed or encapsulated (22.7) =="
if n ip -d link show type vxlan | grep -q vxlan; then
  ok "VXLAN present -- this cluster uses an overlay"
elif n ip link show tunl0 >/dev/null 2>&1; then
  ok "tunl0 present -- IPIP encapsulation"
else
  ok "no vxlan and no tunl0 -- routed, so those via-routes are the whole mechanism"
fi

echo "== 5. A real allocation, end to end =="
kubectl delete pod cni-verify --force --grace-period=0 >/dev/null 2>&1
kubectl run cni-verify --image=busybox:1.36 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\"}}" -- sleep 300 >/dev/null 2>&1
if kubectl wait --for=condition=Ready pod/cni-verify --timeout=90s >/dev/null 2>&1; then
  ok "a pod was created on $NODE (so the CNI ADD path works)"
  PIP=$(kubectl get pod cni-verify -o jsonpath='{.status.podIP}')
  echo "        pod IP: $PIP"
  holder=$(n sh -c "cat /var/lib/cni/networks/*/$PIP 2>/dev/null" | head -c 40)
  [ -n "$holder" ] && ok "  its address is recorded in IPAM, held by $holder..." \
                   || echo "  NOTE  no host-local file for $PIP (non-host-local IPAM)"
  kubectl delete pod cni-verify --force --grace-period=0 >/dev/null 2>&1
  sleep 5
  if n sh -c "ls /var/lib/cni/networks/*/$PIP" >/dev/null 2>&1; then
    no "  the address was NOT released after deletion -- DEL leaked it"
  else
    ok "  the address was released on delete (CNI DEL succeeded)"
  fi
else
  no "the pod never became Ready -- is the CNI configuration in place?"
  kubectl delete pod cni-verify --force --grace-period=0 >/dev/null 2>&1
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
