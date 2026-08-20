#!/usr/bin/env bash
# CKA 10 verification. Run from the assignment directory:
#   bash solution/verify.sh
NS=cka10
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. Co-located containers =="
rdy=$(kubectl get pod colocated -n $NS -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
[ "$rdy" = "true true" ] && ok "colocated has 2/2 containers ready" \
                         || no "colocated readiness is '${rdy:-missing}', expected 'true true'"

a=$(kubectl exec colocated -n $NS -c writer -- cat /data/index.html 2>/dev/null)
b=$(kubectl exec colocated -n $NS -c web -- cat /usr/share/nginx/html/index.html 2>/dev/null)
[ -n "$a" ] && [ "$a" = "$b" ] && ok "both containers see the same file on the shared volume" \
                               || no "the shared volume does not match between containers"

if kubectl exec colocated -n $NS -c writer -- wget -qO- http://localhost:80 >/dev/null 2>&1; then
  ok "the writer reached the web container over localhost"
else
  no "localhost:80 was not reachable from the writer container"
fi

echo "== 2. Sequential init =="
n=$(kubectl get pod sequential-init -n $NS -o jsonpath='{.status.initContainerStatuses[*].name}' 2>/dev/null | wc -w)
[ "${n:-0}" = "2" ] && ok "sequential-init reports 2 init containers" \
                    || no "expected 2 init containers, found ${n:-0}"

for c in step-one step-two; do
  r=$(kubectl get pod sequential-init -n $NS \
        -o jsonpath="{.status.initContainerStatuses[?(@.name=='$c')].state.terminated.reason}" 2>/dev/null)
  [ "$r" = "Completed" ] && ok "  $c Completed" || no "  $c state is '${r:-not terminated}'"
done

ph=$(kubectl get pod sequential-init -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ph" = "Running" ] && ok "sequential-init is Running" || no "sequential-init phase is '${ph:-missing}'"

echo "== 3. Wait-for-dependency =="
if kubectl get svc database -n $NS >/dev/null 2>&1; then
  ok "the database Service exists"
  ph=$(kubectl get pod waits-for-db -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Running" ] && ok "waits-for-db was released and is Running" \
                        || no "waits-for-db phase is '${ph:-missing}' -- it should have started once DNS resolved"
else
  no "no database Service -- waits-for-db should still be at Init:0/1 (that is correct for step 3a)"
fi

echo "== 4. Native sidecar =="
sp=$(kubectl get pod with-sidecar -n $NS \
       -o jsonpath="{.spec.initContainers[?(@.name=='log-shipper')].restartPolicy}" 2>/dev/null)
[ "$sp" = "Always" ] && ok "log-shipper is an init container with restartPolicy: Always" \
                     || no "log-shipper restartPolicy is '${sp:-unset}', expected Always"

logs=$(kubectl logs with-sidecar -n $NS -c log-shipper 2>/dev/null)
echo "$logs" | grep -q "before the app" && ok "the shipper logged its own start line" \
                                        || no "no shipper start line in the logs"
echo "$logs" | grep -q "\[shipped\] \[app\] started" \
  && ok "the app's FIRST line was shipped -- the ordering guarantee held" \
  || no "the app's first line was not shipped"

ph=$(kubectl get pod with-sidecar -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
case "$ph" in
  Succeeded) ok "the pod Completed -- the sidecar was stopped after the app" ;;
  Running)   echo "  WAIT  with-sidecar is still Running; re-run in ~40s" ;;
  *)         no "with-sidecar phase is '${ph:-missing}'" ;;
esac

echo "== 5. The broken pod, fixed =="
cmd=$(kubectl get pod orange -n $NS -o jsonpath='{.spec.initContainers[0].command[0]}' 2>/dev/null)
[ "$cmd" = "sleep" ] && ok "orange's init command is now 'sleep'" \
                     || no "orange's init command is '${cmd:-missing}' -- still not fixed"
ph=$(kubectl get pod orange -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ph" = "Running" ] && ok "orange is Running" || no "orange phase is '${ph:-missing}'"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
