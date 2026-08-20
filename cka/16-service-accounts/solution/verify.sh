#!/usr/bin/env bash
# CKA 16 verification. Run from the assignment directory:
#   bash solution/verify.sh
NS=cka16
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. ServiceAccounts =="
for s in default dashboard-sa no-token-sa legacy-sa; do
  kubectl get sa "$s" -n $NS >/dev/null 2>&1 && ok "$s exists" || no "$s missing"
done

am=$(kubectl get sa no-token-sa -n $NS -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null)
[ "$am" = "false" ] && ok "no-token-sa has automountServiceAccountToken=false" \
                    || no "no-token-sa automount is '${am:-unset}', expected false"

tok=$(kubectl get sa default -n $NS -o jsonpath='{.secrets}' 2>/dev/null)
[ -z "$tok" ] && ok "the default SA has no auto-created token Secret (1.24+ behaviour)" \
              || echo "  NOTE  default SA lists secrets: $tok -- pre-1.24 cluster?"

echo "== 2. RBAC =="
kind=$(kubectl get rolebinding dashboard-sa-reads-pods -n $NS -o jsonpath='{.subjects[0].kind}' 2>/dev/null)
name=$(kubectl get rolebinding dashboard-sa-reads-pods -n $NS -o jsonpath='{.subjects[0].name}' 2>/dev/null)
[ "$kind" = "ServiceAccount" ] && [ "$name" = "dashboard-sa" ] \
  && ok "the RoleBinding subject is ServiceAccount/dashboard-sa" \
  || no "subject is '${kind:-?}/${name:-?}'"

echo "== 3. Effective permissions =="
a=$(kubectl auth can-i list pods --as=system:serviceaccount:$NS:dashboard-sa -n $NS 2>/dev/null)
[ "$a" = "yes" ] && ok "dashboard-sa CAN list pods in $NS" || no "dashboard-sa cannot list pods (got '${a:-?}')"

b=$(kubectl auth can-i list pods --as=system:serviceaccount:$NS:default -n $NS 2>/dev/null)
[ "$b" = "no" ] && ok "the default SA CANNOT list pods -- as it should be" \
                || no "the default SA can list pods (got '${b:-?}') -- something granted it permissions"

c=$(kubectl auth can-i delete pods --as=system:serviceaccount:$NS:dashboard-sa -n $NS 2>/dev/null)
[ "$c" = "no" ] && ok "dashboard-sa cannot DELETE pods -- the Role is scoped" \
                || no "dashboard-sa can delete pods (got '${c:-?}')"

d=$(kubectl auth can-i list pods --as=system:serviceaccount:$NS:dashboard-sa -n default 2>/dev/null)
[ "$d" = "no" ] && ok "the permission does not leak into other namespaces" \
                || no "dashboard-sa can list pods in 'default' (got '${d:-?}')"

echo "== 4. Token mounting =="
sa=$(kubectl get pod uses-default -n $NS -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
[ "$sa" = "default" ] && ok "uses-default was injected with the default SA" \
                      || no "uses-default serviceAccountName is '${sa:-missing}'"

if kubectl get pod no-token -n $NS >/dev/null 2>&1; then
  v=$(kubectl get pod no-token -n $NS -o jsonpath='{.spec.volumes}' 2>/dev/null)
  case "${v:-[]}" in
    ""|"[]") ok "the no-token pod has no volumes at all" ;;
    *) echo "$v" | grep -q "kube-api-access" \
         && no "the no-token pod still has a projected token volume" \
         || ok "the no-token pod has no kube-api-access volume" ;;
  esac
else
  no "pod no-token not found"
fi

if kubectl get pod pod-overrides -n $NS >/dev/null 2>&1; then
  kubectl get pod pod-overrides -n $NS -o jsonpath='{.spec.volumes}' 2>/dev/null | grep -q "kube-api-access" \
    && ok "pod-overrides DOES have a token -- the pod-level setting won" \
    || no "pod-overrides has no token; the pod-level override did not take effect"
else
  no "pod pod-overrides not found"
fi

echo "== 5. A freshly issued token =="
t=$(kubectl create token dashboard-sa -n $NS 2>/dev/null)
if [ -n "$t" ]; then
  ok "kubectl create token succeeded"
  payload=$(echo "$t" | cut -d. -f2 | base64 -d 2>/dev/null)
  echo "$payload" | grep -q "system:serviceaccount:$NS:dashboard-sa" \
    && ok "  sub = system:serviceaccount:$NS:dashboard-sa" \
    || no "  unexpected sub in the token payload"
  echo "$payload" | grep -q '"exp"' && ok "  the token carries an exp claim" \
                                    || no "  no exp claim -- this token does not expire"
else
  no "kubectl create token failed"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
