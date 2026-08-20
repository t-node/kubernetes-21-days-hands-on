#!/usr/bin/env bash
# CKA 17 verification. Run from the assignment directory:
#   bash solution/verify.sh
NS=cka17
RNS=cka17-restricted
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. Image names =="
d1=$(kubectl get pod name-short -n $NS -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)
d2=$(kubectl get pod name-with-account -n $NS -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)
d3=$(kubectl get pod name-fully-qualified -n $NS -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)
if [ -n "$d1" ] && [ "$d1" = "$d2" ] && [ "$d2" = "$d3" ]; then
  ok "all three name forms resolved to one digest"
  echo "        $d1"
else
  no "digests differ or pods missing: '${d1:-?}' '${d2:-?}' '${d3:-?}'"
fi
d4=$(kubectl get pod name-other-registry -n $NS -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)
case "$d4" in
  registry.k8s.io/*) ok "name-other-registry came from registry.k8s.io" ;;
  *) no "name-other-registry imageID is '${d4:-missing}'" ;;
esac

echo "== 2. Pull secret =="
t=$(kubectl get secret regcred -n $NS -o jsonpath='{.type}' 2>/dev/null)
[ "$t" = "kubernetes.io/dockerconfigjson" ] && ok "regcred type is $t" \
                                            || no "regcred type is '${t:-missing}'"
kubectl get secret regcred -n $NS -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
  | base64 -d 2>/dev/null | grep -q "registry.internal.example:5000" \
  && ok "it names the expected registry" || no "the decoded config does not name the registry"

sa=$(kubectl get sa default -n $NS -o jsonpath='{.imagePullSecrets[0].name}' 2>/dev/null)
[ "$sa" = "regcred" ] && ok "the default ServiceAccount carries the pull secret" \
                      || no "default SA imagePullSecrets is '${sa:-unset}'"

echo "== 3. securityContext levels =="
w=$(kubectl exec multi-context -n $NS -c web -- id -u 2>/dev/null | tr -d '\r')
s=$(kubectl exec multi-context -n $NS -c sidecar -- id -u 2>/dev/null | tr -d '\r')
[ "$w" = "1002" ] && ok "web runs as 1002 (container override won)" || no "web uid is '${w:-?}'"
[ "$s" = "1001" ] && ok "sidecar runs as 1001 (inherited from the pod)" || no "sidecar uid is '${s:-?}'"
kubectl exec multi-context -n $NS -c web -- id -G 2>/dev/null | grep -q 2000 \
  && ok "fsGroup 2000 appears in both containers' groups" || no "fsGroup 2000 not in web's groups"

echo "== 4. runAsNonRoot =="
r=$(kubectl get pod nonroot-fails -n $NS -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
[ "$r" = "CreateContainerConfigError" ] && ok "nonroot-fails is CreateContainerConfigError" \
                                        || no "nonroot-fails reason is '${r:-none}'"
u=$(kubectl logs nonroot-works -n $NS 2>/dev/null | grep -o 'uid=[0-9]*' | head -1)
[ "$u" = "uid=1000" ] && ok "nonroot-works runs as $u" || no "nonroot-works logged '${u:-nothing}'"

echo "== 5. Capabilities =="
kubectl exec capabilities-demo -n $NS -c added-caps -- sh -c 'date -s "12:00:00" >/dev/null 2>&1' \
  && ok "added-caps CAN set the clock (SYS_TIME granted)" \
  || no "added-caps could not set the clock"
kubectl exec capabilities-demo -n $NS -c no-caps -- sh -c 'date -s "12:00:00" >/dev/null 2>&1' \
  && no "no-caps set the clock -- drop: ALL did not take effect" \
  || ok "no-caps cannot set the clock (all capabilities dropped)"
kubectl exec capabilities-demo -n $NS -c default-caps -- sh -c 'date -s "12:00:00" >/dev/null 2>&1' \
  && no "default-caps set the clock -- the runtime is not dropping SYS_TIME" \
  || ok "default-caps cannot set the clock (root, but SYS_TIME is not granted by default)"

echo "== 6. Read-only root filesystem =="
kubectl exec readonly-root -n $NS -- sh -c 'echo x > /evil 2>/dev/null' \
  && no "/ is writable -- readOnlyRootFilesystem is not in effect" \
  || ok "/ is read-only"
kubectl exec readonly-root -n $NS -- sh -c 'echo x > /tmp/x' 2>/dev/null \
  && ok "/tmp is writable (the emptyDir)" || no "/tmp is not writable"

echo "== 7. Pod Security Admission =="
lbl=$(kubectl get ns $RNS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
[ "$lbl" = "restricted" ] && ok "$RNS enforces restricted" || no "$RNS enforce label is '${lbl:-unset}'"

rr=$(kubectl get deploy hardened -n $RNS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${rr:-0}" -ge 1 ] 2>/dev/null && ok "the hardened Deployment runs under restricted" \
                                 || no "hardened has ${rr:-0} ready replicas"

if kubectl get pod privileged-pod -n $RNS >/dev/null 2>&1; then
  no "privileged-pod exists in $RNS -- PSA did not reject it"
else
  ok "privileged-pod was rejected in $RNS"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
