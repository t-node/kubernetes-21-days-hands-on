#!/usr/bin/env bash
# CKA 18 verification. Run against the Calico cluster:
#   kubectl config use-context kind-netpol-lab
#   bash solution/verify.sh
#
# It applies and removes policies as it goes, so run it in the lab namespace
# only. It restores nothing -- re-apply whatever you were testing afterwards.
NS=cka18
PNS=cka18-prod
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

code() {  # code <pod> <host> [namespace] -> HTTP status, or 000 for no answer
  kubectl exec -n "${3:-$NS}" "$1" -- curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://$2" 2>/dev/null || echo "000"
}

echo "== 0. Is anything enforcing policy? =="
cni=$(kubectl get pods -n kube-system -o name 2>/dev/null \
      | grep -oE "calico|cilium|kube-router|kindnet|flannel" | sort -u | tr '\n' ' ')
echo "        CNI pods seen: ${cni:-none}"
case "$cni" in
  *calico*|*cilium*|*kube-router*) ok "a policy-enforcing CNI is present" ;;
  *) no "no policy-enforcing CNI -- run this on kind-netpol-lab after install-calico.sh"; ;;
esac

echo "== 1. Baseline: the flat network =="
kubectl delete netpol --all -n $NS >/dev/null 2>&1
sleep 3
[ "$(code web db)" = "200" ] && ok "web -> db works with no policies" || no "web -> db failed before any policy was applied"
[ "$(code api db)" = "200" ] && ok "api -> db works with no policies" || no "api -> db failed before any policy was applied"

echo "== 2. Default deny actually denies =="
kubectl apply -f "$(dirname "$0")/01-default-deny-ingress.yaml" >/dev/null
sleep 5
[ "$(code web db)" = "000" ] && ok "web -> db is dropped" || no "web -> db still answers -- the policy is not enforced"
[ "$(code api db)" = "000" ] && ok "api -> db is dropped" || no "api -> db still answers"

echo "== 3. One allow, added back =="
kubectl apply -f "$(dirname "$0")/02-db-allow-api.yaml" >/dev/null
sleep 5
[ "$(code api db)" = "200" ] && ok "api -> db is allowed" || no "api -> db is still blocked"
[ "$(code web db)" = "000" ] && ok "web -> db remains blocked" || no "web -> db got through"

echo "== 4. AND versus OR =="
if kubectl get ns $PNS >/dev/null 2>&1; then
  kubectl delete netpol db-allow-api -n $NS >/dev/null 2>&1
  kubectl apply -f "$(dirname "$0")/03-and-rule.yaml" >/dev/null
  sleep 5
  [ "$(code prod-api   db.$NS.svc.cluster.local $PNS)" = "200" ] \
    && ok "AND rule: prod-api is allowed"  || no "AND rule: prod-api was blocked"
  [ "$(code prod-decoy db.$NS.svc.cluster.local $PNS)" = "000" ] \
    && ok "AND rule: prod-decoy is denied" || no "AND rule: prod-decoy got through"

  kubectl delete netpol db-allow-and -n $NS >/dev/null 2>&1
  kubectl apply -f "$(dirname "$0")/04-or-rule.yaml" >/dev/null
  sleep 5
  [ "$(code prod-decoy db.$NS.svc.cluster.local $PNS)" = "200" ] \
    && ok "OR rule: prod-decoy IS allowed -- one dash opened the namespace" \
    || no "OR rule: prod-decoy was denied; the two files may not differ as expected"
  kubectl delete netpol db-allow-or -n $NS >/dev/null 2>&1
else
  echo "  SKIP  $PNS not found -- apply 09-prod-namespace.yaml for part D"
fi

echo "== 5. The DNS trap =="
kubectl delete netpol --all -n $NS >/dev/null 2>&1
kubectl apply -f "$(dirname "$0")/06-egress-no-dns-BAD.yaml" >/dev/null
sleep 5
byname=$(code web api)
API_IP=$(kubectl get pod api-server -n $NS -o jsonpath='{.status.podIP}' 2>/dev/null)
byip=$(code web "$API_IP")
[ "$byname" = "000" ] && ok "by name: blocked (DNS is not allowed)" || no "by name returned $byname -- expected a failure"
[ "$byip"  = "200" ] && ok "by IP:   works (the traffic rule itself is correct)" || no "by IP returned $byip -- the egress rule is wrong too"

kubectl delete netpol web-egress-broken -n $NS >/dev/null 2>&1
kubectl apply -f "$(dirname "$0")/07-egress-with-dns.yaml" >/dev/null
sleep 5
[ "$(code web api)" = "200" ] && ok "with the DNS rule added, by name works again" \
                              || no "still failing by name -- check the kube-dns pod labels"
[ "$(code web db)"  = "000" ] && ok "web -> db is still not allowed by the egress policy" \
                              || no "web -> db got through the egress policy"

kubectl delete netpol --all -n $NS >/dev/null 2>&1

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
