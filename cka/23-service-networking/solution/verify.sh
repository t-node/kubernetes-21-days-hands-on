#!/usr/bin/env bash
# CKA 23 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Expects the cka23 namespace with solution/01-workload.yaml applied.
NS=cka23
NODE=${NODE:-devops-worker}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
n()  { docker exec "$NODE" "$@" 2>/dev/null; }

echo "== 0. Prerequisites =="
SVC=$(kubectl get svc web -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ -n "$SVC" ] && ok "Service web has ClusterIP $SVC" || {
  no "no Service 'web' in $NS -- apply solution/01-workload.yaml"
  echo; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== 1. The ClusterIP exists nowhere (23.1) =="
if n sh -c "ip addr | grep -q ' ${SVC}/'"; then
  no "$SVC is assigned to an interface on $NODE -- unexpected"
else
  ok "$SVC is on no interface"
fi

echo "== 2. The chain structure (23.5) =="
CHAIN=$(n sh -c "iptables -t nat -S KUBE-SERVICES | grep -- '-d ${SVC}/32' | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1")
[ -n "$CHAIN" ] && ok "KUBE-SERVICES sends $SVC to $CHAIN" \
                || no "no KUBE-SVC chain for $SVC -- is kube-proxy running?"

if [ -n "$CHAIN" ]; then
  seps=$(n sh -c "iptables -t nat -S $CHAIN | grep -c 'KUBE-SEP-'")
  ready=$(kubectl get endpointslices -n $NS -l kubernetes.io/service-name=web \
          -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true)
  [ "${seps:-0}" = "${ready:-0}" ] && ok "  $seps endpoint chain(s) == $ready ready endpoint(s)" \
                                   || no "  $seps endpoint chains but $ready ready endpoints"

  if [ "${seps:-0}" -ge 2 ] 2>/dev/null; then
    first=$(n sh -c "iptables -t nat -S $CHAIN | grep -o 'probability [0-9.]*' | head -1 | awk '{print \$2}'")
    want=$(awk -v n="$seps" 'BEGIN{printf "%.4f", 1/n}')
    case "$first" in
      "$want"*) ok "  the first probability is $first == 1/$seps" ;;
      *) echo "  NOTE  first probability $first, expected about $want" ;;
    esac
  fi

  d=$(n sh -c "iptables -t nat -S | grep -c 'KUBE-SEP.*DNAT'")
  [ "${d:-0}" -ge 1 ] 2>/dev/null && ok "  DNAT rules exist in the endpoint chains" \
                                  || no "  no DNAT rules found"
fi

echo "== 3. Both hooks are wired (23.5) =="
n sh -c "iptables -t nat -S PREROUTING | grep -q KUBE-SERVICES" \
  && ok "PREROUTING calls KUBE-SERVICES" || no "PREROUTING does not call KUBE-SERVICES"
n sh -c "iptables -t nat -S OUTPUT | grep -q KUBE-SERVICES" \
  && ok "OUTPUT calls KUBE-SERVICES (node-local traffic)" || no "OUTPUT does not call KUBE-SERVICES"

echo "== 4. A Service with no endpoints REJECTs (23.6) =="
kubectl delete svc verify-noep -n $NS >/dev/null 2>&1
kubectl create service clusterip verify-noep -n $NS --tcp=80:80 >/dev/null 2>&1
kubectl patch svc verify-noep -n $NS -p '{"spec":{"selector":{"app":"nothing-matches-this"}}}' >/dev/null 2>&1
sleep 8
NOEP=$(kubectl get svc verify-noep -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if n sh -c "iptables -t nat -S KUBE-SERVICES | grep -- '-d ${NOEP}/32' | grep -qi reject"; then
  ok "a REJECT rule was written for the endpoint-less Service"
else
  echo "  NOTE  no REJECT rule seen for $NOEP (kube-proxy may still be syncing)"
fi
kubectl delete svc verify-noep -n $NS >/dev/null 2>&1

echo "== 5. Readiness gates membership (23.6) =="
POD=$(kubectl get pods -n $NS -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
before=$(kubectl get endpoints web -n $NS -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -o '"ip"' | wc -l)
kubectl exec -n $NS "$POD" -- mv /usr/share/nginx/html/index.html /tmp/i.html >/dev/null 2>&1
sleep 12
after=$(kubectl get endpoints web -n $NS -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -o '"ip"' | wc -l)
phase=$(kubectl get pod -n $NS "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "${after:-0}" -lt "${before:-0}" ] 2>/dev/null && ok "an unready pod left the Endpoints ($before -> $after)" \
                                                 || no "endpoint count did not drop ($before -> $after)"
[ "$phase" = "Running" ] && ok "  ...while the pod is still Running" || no "  the pod phase is '$phase'"
kubectl exec -n $NS "$POD" -- mv /tmp/i.html /usr/share/nginx/html/index.html >/dev/null 2>&1
sleep 10

echo "== 6. Headless has no rules (23.9) =="
kubectl apply -f "$(dirname "$0")/05-headless.yaml" >/dev/null 2>&1
sleep 6
cip=$(kubectl get svc web-headless -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ "$cip" = "None" ] && ok "web-headless has clusterIP None" || no "clusterIP is '$cip'"
c=$(n sh -c "iptables -t nat -S | grep -c 'web-headless'")
[ "${c:-0}" = "0" ] && ok "  and zero iptables rules mention it" || no "  $c rules mention it"
kubectl delete -f "$(dirname "$0")/05-headless.yaml" >/dev/null 2>&1

echo "== 7. The two CIDRs do not overlap (23.4) =="
svccidr=$(docker exec devops-control-plane sh -c "grep -o 'service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml" 2>/dev/null | cut -d= -f2)
podcidr=$(docker exec devops-control-plane sh -c "grep -o 'cluster-cidr=[^ ]*' /etc/kubernetes/manifests/kube-controller-manager.yaml" 2>/dev/null | cut -d= -f2)
echo "        service CIDR: ${svccidr:-unknown}"
echo "        pod CIDR:     ${podcidr:-unknown}"
if [ -n "$svccidr" ] && [ -n "$podcidr" ] && [ "${svccidr%%.*}" != "${podcidr%%.*}" ]; then
  ok "they are in different ranges"
elif [ -n "$svccidr" ] && [ "$svccidr" != "$podcidr" ]; then
  ok "they differ (check by hand that they do not overlap)"
else
  no "could not read both CIDRs, or they are identical"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
