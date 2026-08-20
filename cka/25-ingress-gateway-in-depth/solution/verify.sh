#!/usr/bin/env bash
# CKA 25 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Expects the cka25 namespace with 01-backends.yaml, 02-pathtype-precedence.yaml
# and 03-rewrite-correct.yaml applied, and ingress-nginx running.
NS=cka25
BASE=${BASE:-http://localhost:8080}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
HERE="$(cd "$(dirname "$0")" && pwd)"

get() { curl -s -m 5 -H "Host: $1" "${BASE}$2" 2>/dev/null; }

echo "== 0. Prerequisites =="
CTRL=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name 2>/dev/null | head -1)
[ -n "$CTRL" ] && ok "ingress-nginx controller found" || {
  no "no ingress-nginx controller -- do Day 20 Step 1 first"
  echo; echo "== 0 passed, 1 failed =="; exit 1; }
kubectl get ingress precedence -n $NS >/dev/null 2>&1 && ok "the precedence Ingress exists" \
  || no "apply solution/02-pathtype-precedence.yaml first"

echo "== 1. The Service is not in the data path (25.1) =="
backends=$(kubectl exec -n ingress-nginx "$CTRL" -- \
  curl -s -m5 http://127.0.0.1:10246/configuration/backends 2>/dev/null)
cip=$(kubectl get svc api -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
podips=$(kubectl get endpointslices -n $NS -l kubernetes.io/service-name=api \
         -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null | head -1)
if [ -n "$backends" ]; then
  echo "$backends" | grep -q "$cip" \
    && no "the ClusterIP $cip appears in the controller's backends -- unexpected" \
    || ok "the ClusterIP $cip is NOT in the controller's backend list"
  [ -n "$podips" ] && echo "$backends" | grep -q "$podips" \
    && ok "  pod IP $podips IS in the backend list" \
    || no "  pod IP ${podips:-?} not found in the backend list"
else
  echo "  NOTE  could not read /configuration/backends (older controller?); skipping"
fi

echo "== 2. Path precedence (25.2) =="
check() {  # check <path> <expected-substring> <why>
  got=$(get paths.local "$1")
  case "$got" in
    *"$2"*) ok "  $1 -> $2   ($3)" ;;
    *) no "  $1 returned '${got:-nothing}', expected $2   ($3)" ;;
  esac
}
check "/"                       "ROOT"         "the / Prefix rule"
check "/dashboard"              "ROOT"         "nothing longer matches"
check "/api/v1/users"           "API"          "/api Prefix, longest match"
check "/api/v1/health"          "HEALTH-EXACT" "Exact beats an equal-length Prefix"
check "/api/v1/healthcheck"     "API"          "Exact did not match; /api Prefix did"
check "/apiary"                 "ROOT"         "Prefix is element-wise, not string-wise"

echo "== 3. The rewrite (25.3) =="
if kubectl get ingress rewrite-ok -n $NS >/dev/null 2>&1; then
  got=$(get rewrite.local /api/v1/users)
  case "$got" in
    *"path=/v1/users"*) ok "the prefix was stripped: $got" ;;
    *) no "expected path=/v1/users, got '${got:-nothing}'" ;;
  esac
  pt=$(kubectl get ingress rewrite-ok -n $NS -o jsonpath='{.spec.rules[0].http.paths[0].pathType}')
  [ "$pt" = "ImplementationSpecific" ] && ok "  its pathType is ImplementationSpecific" \
                                       || no "  pathType is '$pt' -- a regex needs ImplementationSpecific"
else
  echo "  SKIP  rewrite-ok not applied"
fi

echo "== 4. The same rewrite with pathType: Prefix silently 404s =="
kubectl apply -f "${HERE}/04-rewrite-BAD.yaml" >/dev/null 2>&1
sleep 6
code=$(curl -s -m5 -o /dev/null -w "%{http_code}" -H "Host: broken.local" "${BASE}/api/v1/users" 2>/dev/null)
[ "$code" = "404" ] && ok "the Prefix-typed regex returns 404 (no error anywhere else)" \
                    || no "expected 404, got '${code:-nothing}'"
addr=$(kubectl get ingress rewrite-broken -n $NS -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
[ -n "$addr" ] && ok "  ...while ADDRESS is populated ($addr) -- nothing looks wrong" \
               || echo "  NOTE  ADDRESS is empty; the controller may still be syncing"
kubectl delete -f "${HERE}/04-rewrite-BAD.yaml" >/dev/null 2>&1

echo "== 5. An unclaimed Ingress has no ADDRESS (25.4) =="
kubectl apply -f "${HERE}/05-no-class-BAD.yaml" >/dev/null 2>&1
sleep 10
a=$(kubectl get ingress orphan -n $NS -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)
[ -z "$a" ] && ok "the orphan Ingress has an empty ADDRESS" \
            || no "it was adopted by something: $a"
kubectl get ingressclass nginx-internal >/dev/null 2>&1 \
  && no "  an IngressClass 'nginx-internal' exists -- the test is invalid" \
  || ok "  and no IngressClass by that name exists"
kubectl delete -f "${HERE}/05-no-class-BAD.yaml" >/dev/null 2>&1

echo "== 6. Gateway API (25.5, 25.6) =="
if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  ok "the Gateway API CRDs are installed"
  if kubectl get httproute route-refused -n $NS >/dev/null 2>&1; then
    r=$(kubectl get httproute route-refused -n $NS \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null)
    case "$r" in
      NotAllowedByListeners) ok "  route-refused: Accepted=False, reason=$r" ;;
      Accepted) echo "  NOTE  route-refused is now Accepted -- is the namespace still labelled?" ;;
      *) no "  unexpected reason '${r:-none}'" ;;
    esac
  else
    echo "  SKIP  route-refused not applied"
  fi
  if kubectl get httproute route-crossns -n $NS >/dev/null 2>&1; then
    r=$(kubectl get httproute route-crossns -n $NS \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].reason}' 2>/dev/null)
    if kubectl get referencegrant -n cka25-data >/dev/null 2>&1 \
       && [ -n "$(kubectl get referencegrant -n cka25-data -o name 2>/dev/null)" ]; then
      [ "$r" = "ResolvedRefs" ] && ok "  with a ReferenceGrant, ResolvedRefs=$r" \
                               || no "  a grant exists but ResolvedRefs reason is '${r:-none}'"
    else
      [ "$r" = "RefNotPermitted" ] && ok "  without a grant, ResolvedRefs reason=$r" \
                                  || no "  expected RefNotPermitted, got '${r:-none}'"
    fi
  else
    echo "  SKIP  route-crossns not applied"
  fi
else
  echo "  SKIP  Gateway API CRDs not installed -- do Day 20 Step 7 for part 7-9"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
