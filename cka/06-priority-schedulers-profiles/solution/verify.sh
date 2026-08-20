#!/usr/bin/env bash
# CKA 06 verification. Run from the assignment directory:
#   bash solution/verify.sh
NS=cka06
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
no()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. Priority classes =="
for c in low-priority:1000 high-priority:1000000 patient-priority:1000000; do
  name=${c%%:*}; want=${c##*:}
  got=$(kubectl get priorityclass "$name" -o jsonpath='{.value}' 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$name = $want"; else no "$name expected $want, got '${got:-missing}'"; fi
done

pol=$(kubectl get priorityclass patient-priority -o jsonpath='{.preemptionPolicy}' 2>/dev/null)
[ "$pol" = "Never" ] && ok "patient-priority preemptionPolicy=Never" \
                     || no "patient-priority preemptionPolicy is '${pol:-unset}', expected Never"

scope=$(kubectl get priorityclass low-priority -o jsonpath='{.metadata.namespace}' 2>/dev/null)
[ -z "$scope" ] && ok "PriorityClass is cluster-scoped (no namespace)" \
                || no "unexpected namespace '$scope'"

echo "== 2. Preemption actually happened =="
if kubectl get events -n "$NS" --field-selector reason=Preempted 2>/dev/null | grep -q Preempted; then
  ok "a Preempted event was recorded in $NS"
  kubectl get events -n "$NS" --field-selector reason=Preempted \
    -o custom-columns=VICTIM:.involvedObject.name,MSG:.message --no-headers 2>/dev/null | head -3 | sed 's/^/        /'
else
  no "no Preempted event in $NS -- did step 3 run? (events expire after ~1h)"
fi

echo "== 3. preemptionPolicy: Never =="
if kubectl get pod patient-app -n "$NS" >/dev/null 2>&1; then
  ph=$(kubectl get pod patient-app -n "$NS" -o jsonpath='{.status.phase}')
  [ "$ph" = "Pending" ] && ok "patient-app is Pending (waited, did not evict)" \
                        || no "patient-app is $ph -- expected Pending on a full cluster"
else
  echo "  SKIP  patient-app not present (deleted after step 4 -- fine)"
fi

echo "== 4. Second scheduler =="
rdy=$(kubectl get deploy my-scheduler -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${rdy:-0}" -ge 1 ] 2>/dev/null && ok "my-scheduler Deployment has $rdy ready replica(s)" \
                                  || no "my-scheduler not ready (readyReplicas='${rdy:-0}')"

sn=$(kubectl get pod uses-custom-scheduler -n "$NS" -o jsonpath='{.spec.schedulerName}' 2>/dev/null)
[ "$sn" = "my-scheduler" ] && ok "uses-custom-scheduler requests schedulerName=my-scheduler" \
                           || no "schedulerName is '${sn:-missing}'"

node=$(kubectl get pod uses-custom-scheduler -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[ -n "$node" ] && ok "uses-custom-scheduler was bound to $node" \
               || no "uses-custom-scheduler is still unbound"

src=$(kubectl get events -n "$NS" --field-selector involvedObject.name=uses-custom-scheduler,reason=Scheduled \
        -o jsonpath='{.items[0].source.component}' 2>/dev/null)
[ "$src" = "my-scheduler" ] && ok "the Scheduled event came FROM my-scheduler" \
                           || no "Scheduled event source is '${src:-none}', expected my-scheduler"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
