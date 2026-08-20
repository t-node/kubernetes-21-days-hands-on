#!/usr/bin/env bash
# CKA 07 verification. Run from the assignment directory:
#   bash solution/verify.sh
CP=${CP:-devops-control-plane}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. Built-in plugins =="
if docker exec "$CP" kube-apiserver -h 2>/dev/null | grep -q "enable-admission-plugins"; then
  ok "the default plugin list is readable from the binary"
else
  no "could not read 'kube-apiserver -h' on $CP"
fi

cfg=$(docker exec "$CP" grep -c "disable-admission-plugins" \
      /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null || echo 0)
[ "$cfg" = "0" ] && ok "no --disable-admission-plugins left behind" \
                 || no "--disable-admission-plugins is still set -- run: bash solution/toggle-plugin.sh del-disable DefaultStorageClass"

if docker exec "$CP" grep -q "NamespaceAutoProvision" \
     /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
  no "NamespaceAutoProvision still enabled -- run: bash solution/toggle-plugin.sh del-enable NamespaceAutoProvision"
else
  ok "NamespaceAutoProvision removed again"
fi

echo "== 2. Webhook server =="
rdy=$(kubectl get deploy webhook-server -n webhook-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${rdy:-0}" -ge 1 ] 2>/dev/null && ok "webhook-server has $rdy ready replica(s)" \
                                  || no "webhook-server not ready (readyReplicas='${rdy:-0}')"

for k in mutatingwebhookconfiguration:pod-policy-mutate.example.com \
         validatingwebhookconfiguration:pod-policy-validate.example.com; do
  kind=${k%%:*}; name=${k##*:}
  if kubectl get "$kind" "$name" >/dev/null 2>&1; then
    ok "$kind/$name exists"
    ca=$(kubectl get "$kind" "$name" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null)
    [ -n "$ca" ] && [ "$ca" != "CA_BUNDLE_PLACEHOLDER" ] \
      && ok "  caBundle was substituted" || no "  caBundle is empty or still the placeholder"
  else
    no "$kind/$name missing"
  fi
done

echo "== 3. Mutation =="
sc=$(kubectl get pod pod-with-defaults -n cka07 -o jsonpath='{.spec.securityContext.runAsUser}' 2>/dev/null)
[ "$sc" = "1234" ] && ok "pod-with-defaults got runAsUser=1234 injected" \
                   || no "pod-with-defaults runAsUser='${sc:-missing}', expected 1234"

ov=$(kubectl get pod pod-with-override -n cka07 -o jsonpath='{.spec.securityContext.runAsUser}' 2>/dev/null)
[ -z "$ov" ] && ok "pod-with-override was left alone (no UID forced)" \
             || no "pod-with-override unexpectedly has runAsUser=$ov"

echo "== 4. Validation =="
if kubectl get pod pod-with-conflict -n cka07 >/dev/null 2>&1; then
  no "pod-with-conflict exists -- the validating webhook did not reject it"
else
  ok "pod-with-conflict was rejected (does not exist)"
fi

echo "== 5. ValidatingAdmissionPolicy =="
if kubectl get validatingadmissionpolicy pod-image-and-label-policy >/dev/null 2>&1; then
  ok "policy pod-image-and-label-policy exists"
  n=$(kubectl get validatingadmissionpolicybinding -o name 2>/dev/null | grep -c pod-image-and-label-policy)
  [ "${n:-0}" -ge 2 ] && ok "  $n bindings (enforce + warn)" || no "  expected 2 bindings, found ${n:-0}"
else
  no "policy pod-image-and-label-policy missing"
fi

if kubectl get pod latest-tag-pod -n enforced >/dev/null 2>&1; then
  no "latest-tag-pod exists in 'enforced' -- Deny binding did not fire"
else
  ok "latest-tag-pod was denied in the enforced namespace"
fi

if kubectl get pod latest-tag-pod -n warned >/dev/null 2>&1; then
  ok "latest-tag-pod WAS created in the warned namespace (Warn, not Deny)"
else
  no "latest-tag-pod missing from 'warned' -- it should have been warned, not blocked"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
