#!/usr/bin/env bash
# CKA 31 verification -- confirms the cluster is back to a healthy baseline.
#
#   bash solution/verify.sh
#
# Run it after restore.sh. Unlike other assignments' verify scripts, this one
# checks that NOTHING is broken rather than that something was built.
NS=cka31
CP=${CP:-devops-control-plane}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. Nodes (31.5) =="
if ! kubectl get nodes >/dev/null 2>&1; then
  no "kubectl cannot reach the API server"
  echo "        try: docker exec $CP crictl ps -a | grep apiserver"
  echo; echo "== $pass passed, $((fail)) failed =="; exit 1
fi
total=$(kubectl get nodes --no-headers | wc -l)
ready=$(kubectl get nodes --no-headers | grep -c " Ready")
[ "${ready:-0}" -eq "${total:-0}" ] 2>/dev/null && ok "$ready of $total nodes Ready" \
                                                || no "only ${ready:-0} of ${total:-0} nodes Ready"
sched=$(kubectl get nodes --no-headers | grep -c "SchedulingDisabled")
[ "${sched:-1}" = "0" ] && ok "  none are cordoned" || no "  ${sched} node(s) still cordoned"

taints=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].key}{"\n"}{end}' \
         2>/dev/null | grep -v "node-role.kubernetes.io/control-plane" | grep -c "[a-z]" )
if kubectl get nodes -o json 2>/dev/null | grep -q '"key": *"maintenance"'; then
  no "  a maintenance taint is still present -- run restore.sh"
else
  ok "  no leftover maintenance taints"
fi

echo "== 2. Control plane (31.4) =="
for c in kube-apiserver kube-scheduler kube-controller-manager etcd; do
  r=$(kubectl -n kube-system get pods -l component=$c --no-headers 2>/dev/null | grep -c "Running")
  [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "  $c Running" || no "  $c is not Running"
done
for l in kube-scheduler kube-controller-manager; do
  h=$(kubectl -n kube-system get lease "$l" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
  [ -n "$h" ] && ok "  $l holds its lease" || no "  $l has no lease holder -- is it running?"
done

echo "== 3. The scheduler is actually scheduling =="
kubectl -n kube-system delete pod ts-probe >/dev/null 2>&1
kubectl run ts-probe -n kube-system --image=busybox:1.36 --restart=Never -- sleep 60 >/dev/null 2>&1
sleep 8
node=$(kubectl -n kube-system get pod ts-probe -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[ -n "$node" ] && ok "a new pod was scheduled onto $node" \
               || no "a new pod was never assigned a node -- is the scheduler running?"
kubectl -n kube-system delete pod ts-probe --force --grace-period=0 >/dev/null 2>&1

echo "== 4. The controller manager is actually reconciling =="
kubectl -n kube-system delete deployment ts-probe-d >/dev/null 2>&1
kubectl create deployment ts-probe-d -n kube-system --image=busybox:1.36 -- sleep 60 >/dev/null 2>&1
sleep 8
rs=$(kubectl -n kube-system get rs -l app=ts-probe-d --no-headers 2>/dev/null | wc -l)
[ "${rs:-0}" -ge 1 ] 2>/dev/null && ok "a Deployment produced a ReplicaSet" \
                                 || no "no ReplicaSet was created -- is the controller manager running?"
kubectl -n kube-system delete deployment ts-probe-d >/dev/null 2>&1

echo "== 5. DNS (31.6) =="
ep=$(kubectl -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -c '"ip"')
[ "${ep:-0}" -ge 1 ] 2>/dev/null && ok "kube-dns has $ep endpoint(s)" \
                                 || no "kube-dns has no endpoints -- is CoreDNS scaled to 0?"

echo "== 6. The application (31.3) =="
if kubectl get ns $NS >/dev/null 2>&1; then
  for d in web db; do
    r=$(kubectl -n $NS get deploy $d -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    want=$(kubectl -n $NS get deploy $d -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [ "${r:-0}" = "${want:-x}" ] && ok "  $d: $r/$want ready" || no "  $d: ${r:-0}/${want:-?} ready"
  done
  for s in web db; do
    n=$(kubectl -n $NS get endpoints $s -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -c '"ip"')
    [ "${n:-0}" -ge 1 ] 2>/dev/null && ok "  Service $s has $n endpoint(s)" \
                                    || no "  Service $s has no endpoints (31.3)"
  done
  code=$(kubectl -n $NS exec client -- curl -s -m5 -o /dev/null -w "%{http_code}" http://web 2>/dev/null)
  [ "$code" = "200" ] && ok "  end to end: web -> $code" || no "  end to end: web -> ${code:-no answer}"
  code=$(kubectl -n $NS exec client -- curl -s -m5 -o /dev/null -w "%{http_code}" http://db:5432 2>/dev/null)
  [ "$code" = "200" ] && ok "  end to end: db  -> $code" || no "  end to end: db  -> ${code:-no answer}"
else
  echo "  SKIP  the $NS namespace does not exist -- apply solution/app.yaml"
fi

echo
if [ -f "$(dirname "$0")/.broken" ]; then
  echo "NOTE  solution/.broken still exists -- a scenario may still be applied."
  echo "      Run: bash solution/restore.sh all"
fi
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
