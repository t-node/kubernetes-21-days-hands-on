#!/usr/bin/env bash
# CKA 26 verification. Run from the assignment directory, against the HA cluster:
#   kubectl config use-context kind-ha-lab
#   bash solution/verify.sh
CTX=${CTX:-kind-ha-lab}
PREFIX="${CTX#kind-}"
LB="${PREFIX}-external-load-balancer"
K="kubectl --context=$CTX"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 0. Is the HA cluster there? =="
if $K get nodes >/dev/null 2>&1; then ok "context $CTX responds"; else
  no "cannot reach $CTX -- create it with: kind create cluster --config solution/kind-ha.yaml"
  echo; echo "== 0 passed, 1 failed =="; exit 1; fi

echo "== 1. Three control planes (26.4) =="
n=$($K get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)
[ "${n:-0}" -eq 3 ] 2>/dev/null && ok "$n control-plane nodes" || no "found ${n:-0} control-plane nodes, expected 3"
ready=$($K get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | grep -c " Ready")
[ "${ready:-0}" -eq "${n:-0}" ] 2>/dev/null && ok "  all $ready are Ready" \
                                            || no "  only ${ready:-0} of ${n:-0} are Ready"

echo "== 2. The load balancer kind created (26.4) =="
if docker ps --filter "name=${LB}" --format '{{.Names}}' | grep -q .; then
  ok "$LB is running"
  b=$(docker exec "$LB" grep -c "6443" /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null)
  [ "${b:-0}" -ge 3 ] 2>/dev/null && ok "  its config lists $b API server backends" \
                                  || no "  expected 3 backends, found ${b:-0}"
else
  no "no $LB container -- is this a multi-control-plane cluster?"
fi

srv=$($K config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
echo "        kubeconfig server: $srv"
nodeips=$($K get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)
hit=0
for ip in $nodeips; do case "$srv" in *"$ip"*) hit=1 ;; esac; done
[ "$hit" -eq 0 ] && ok "  it points at the load balancer, not at any node" \
                 || no "  it points directly at a node -- no HA on the client side"

echo "== 3. Active/active vs active/passive (26.4) =="
for c in kube-apiserver kube-scheduler kube-controller-manager; do
  r=$($K -n kube-system get pods -l component=$c --no-headers 2>/dev/null | grep -c "Running")
  [ "${r:-0}" -eq 3 ] 2>/dev/null && ok "3 $c pods Running" || no "${r:-0} $c pods Running, expected 3"
done

echo "== 4. Leases -- exactly one holder each (26.4) =="
for l in kube-scheduler kube-controller-manager; do
  h=$($K -n kube-system get lease "$l" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
  [ -n "$h" ] && ok "$l holder: ${h%%_*}" || no "$l has no holder"
done
t1=$($K -n kube-system get lease kube-scheduler -o jsonpath='{.spec.renewTime}' 2>/dev/null)
sleep 12
t2=$($K -n kube-system get lease kube-scheduler -o jsonpath='{.spec.renewTime}' 2>/dev/null)
[ -n "$t1" ] && [ "$t1" != "$t2" ] && ok "  the lease is being renewed (heartbeat is alive)" \
                                   || no "  renewTime did not advance in 12s -- the holder may be dead"

echo "== 5. etcd membership and leader (26.5) =="
CP="${PREFIX}-control-plane"
E() { $K -n kube-system exec "etcd-${CP}" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key "$@" 2>/dev/null; }

m=$(E member list | grep -c "started")
[ "${m:-0}" -eq 3 ] 2>/dev/null && ok "$m etcd members" || no "${m:-0} etcd members, expected 3"

st=$(E endpoint status --cluster --write-out=table)
lead=$(echo "$st" | grep -c "true")
[ "${lead:-0}" -eq 1 ] 2>/dev/null && ok "  exactly one member reports IS LEADER" \
                                   || no "  ${lead:-0} members claim leadership"
h=$(E endpoint health --cluster 2>&1 | grep -c "healthy: true")
[ "${h:-0}" -eq 3 ] 2>/dev/null && ok "  all 3 members are healthy" || echo "  NOTE  ${h:-0} of 3 report healthy"

echo "== 6. Quorum arithmetic (26.5) =="
q=$(( ${n:-3} / 2 + 1 ))
tol=$(( ${n:-3} - q ))
echo "        members=${n} quorum=${q} tolerates=${tol}"
[ "$q" -eq 2 ] && [ "$tol" -eq 1 ] && ok "3 members -> quorum 2, tolerates 1" \
                                   || no "unexpected arithmetic for ${n} members"

echo "== 7. Topology (26.6) =="
e=$($K -n kube-system get pods -l component=etcd --no-headers 2>/dev/null | wc -l)
[ "${e:-0}" -eq 3 ] 2>/dev/null && ok "etcd runs as static pods on the control planes -> STACKED" \
                                || echo "  NOTE  ${e:-0} etcd pods -- external topology?"
es=$(docker exec "$CP" grep -o -- "--etcd-servers=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null)
echo "        $es"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
