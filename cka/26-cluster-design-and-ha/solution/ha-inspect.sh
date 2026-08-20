#!/usr/bin/env bash
# Everything about this cluster's high availability, in one pass.
#
#   bash solution/ha-inspect.sh
#
# Run it against the ha-lab cluster:
#   kubectl config use-context kind-ha-lab
set -uo pipefail
CTX=${CTX:-kind-ha-lab}
LB=${LB:-ha-lab-external-load-balancer}
K="kubectl --context=$CTX"
say() { echo; echo "=== $*"; }

say "1. the nodes"
$K get nodes -o wide 2>/dev/null

say "2. the load balancer kind created for you (26.4)"
docker ps --filter "name=${LB}" --format "  {{.Names}}  {{.Image}}  {{.Ports}}" 2>/dev/null \
  || echo "  (no external load balancer container -- is this a multi-control-plane cluster?)"
echo
echo "-- its configuration, listing every API server behind it:"
docker exec "$LB" cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null \
  | grep -A10 "backend" | sed 's/^/     /'

say "3. where your kubeconfig actually points"
$K config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}' 2>/dev/null
echo "-- compare with the API server addresses above: you talk to the LB, not a node."

say "4. the API servers -- ACTIVE/ACTIVE, all three serving (26.4)"
$K -n kube-system get pods -l component=kube-apiserver -o wide 2>/dev/null

say "5. the scheduler and controller manager -- all running, ONE active"
$K -n kube-system get pods -l component=kube-scheduler -o wide 2>/dev/null
$K -n kube-system get pods -l component=kube-controller-manager -o wide 2>/dev/null

say "6. who holds the leases? (26.4)"
$K -n kube-system get lease 2>/dev/null | head -8
echo
for l in kube-scheduler kube-controller-manager; do
  h=$($K -n kube-system get lease "$l" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
  t=$($K -n kube-system get lease "$l" -o jsonpath='{.spec.renewTime}' 2>/dev/null)
  printf "  %-26s holder=%s\n" "$l" "${h:-none}"
  printf "  %-26s renewed=%s\n" "" "${t:-?}"
done
echo
echo "-- the timings that govern failover:"
docker exec "${CTX#kind-}-control-plane" sh -c \
  "grep -h 'leader-elect' /etc/kubernetes/manifests/kube-scheduler.yaml 2>/dev/null" | sed 's/^/     /'
echo "     (absent means the defaults: lease 15s, renew 10s, retry 2s)"

say "7. the etcd cluster (26.5)"
CP="${CTX#kind-}-control-plane"
E="$K -n kube-system exec etcd-${CP} -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"
$E member list --write-out=table 2>/dev/null | sed 's/^/  /'
echo
echo "-- which member is the LEADER, and is every member healthy:"
$E endpoint status --cluster --write-out=table 2>/dev/null | sed 's/^/  /'

say "8. quorum arithmetic for this cluster"
n=$($K get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)
q=$(( n / 2 + 1 ))
echo "  members:        $n"
echo "  quorum:         $q     (floor(N/2)+1)"
echo "  can afford to lose: $(( n - q ))"

say "9. the topology (26.6)"
if $K -n kube-system get pods -l component=etcd --no-headers 2>/dev/null | grep -q .; then
  echo "  etcd runs as static pods ON the control-plane nodes -> STACKED"
  $K -n kube-system get pods -l component=etcd -o wide 2>/dev/null | sed 's/^/  /'
else
  echo "  no etcd pods in the cluster -> EXTERNAL etcd"
fi
echo
echo "-- what the API server was told to talk to:"
docker exec "$CP" grep -o -- "--etcd-servers=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | sed 's/^/     /'
