#!/usr/bin/env bash
# CKA 24 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Expects the cka24 namespace with 01-workload.yaml and 02-dnsutils.yaml applied.
NS=cka24
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
D()  { kubectl exec -n $NS dnsutils -- "$@" 2>/dev/null; }

echo "== 0. Prerequisites =="
kubectl get pod dnsutils -n $NS >/dev/null 2>&1 && ok "the dnsutils pod exists" || {
  no "no dnsutils pod -- apply solution/02-dnsutils.yaml"
  echo; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== 1. The CoreDNS installation (24.2) =="
for o in "deployment/coredns" "service/kube-dns" "configmap/coredns"; do
  kubectl -n kube-system get "$o" >/dev/null 2>&1 && ok "$o exists" || no "$o missing"
done
r=$(kubectl -n kube-system get deployment coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${r:-0}" -ge 1 ] 2>/dev/null && ok "  $r CoreDNS replica(s) ready" || no "  no ready replicas"

ep=$(kubectl -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -c '"ip"')
[ "${ep:-0}" -ge 1 ] 2>/dev/null && ok "  the kube-dns Service has $ep endpoint(s)" || no "  kube-dns has no endpoints"

echo "== 2. clusterDNS matches the Service ClusterIP (24.4) =="
cip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
kdns=$(docker exec devops-control-plane grep -A2 clusterDNS /var/lib/kubelet/config.yaml 2>/dev/null \
       | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
echo "        Service ClusterIP: ${cip:-?}   kubelet clusterDNS: ${kdns:-?}"
[ -n "$cip" ] && [ "$cip" = "$kdns" ] && ok "they match" \
                                     || no "they differ -- new pods would get a broken resolver"

rc=$(D cat /etc/resolv.conf | grep -c "$cip")
[ "${rc:-0}" -ge 1 ] 2>/dev/null && ok "  the pod's resolv.conf points at $cip" \
                                 || no "  the pod's nameserver is not $cip"

echo "== 3. A Service resolves by all four forms (24.1) =="
want=$(kubectl get svc web -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
for name in "web" "web.$NS" "web.$NS.svc" "web.$NS.svc.cluster.local"; do
  got=$(D dig +short "$name" | head -1)
  [ "$got" = "$want" ] && ok "  $name -> $got" || no "  $name returned '${got:-nothing}', expected $want"
done

echo "== 4. Headless returns one record per endpoint (24.1) =="
n=$(D dig +short "web-headless.$NS.svc.cluster.local" | grep -c '^[0-9]')
ready=$(kubectl get endpointslices -n $NS -l kubernetes.io/service-name=web-headless \
        -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true)
[ "${n:-0}" = "${ready:-0}" ] && [ "${n:-0}" -ge 2 ] 2>/dev/null \
  && ok "$n A records == $ready ready endpoints" \
  || no "$n A records but $ready ready endpoints"

cip2=$(kubectl get svc web-headless -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ "$cip2" = "None" ] && ok "  and it has no ClusterIP" || no "  clusterIP is '$cip2'"

echo "== 5. StatefulSet pod names (24.1) =="
for p in web-0 web-1; do
  want=$(kubectl get pod "$p" -n $NS -o jsonpath='{.status.podIP}' 2>/dev/null)
  got=$(D dig +short "${p}.web-headless.${NS}.svc.cluster.local" | head -1)
  [ -n "$want" ] && [ "$got" = "$want" ] && ok "  $p resolves to its own address" \
                                        || no "  $p -> '${got:-nothing}', expected ${want:-?}"
done

echo "== 6. SRV carries the named port (24.1) =="
srv=$(D dig SRV +short "_http._tcp.web.${NS}.svc.cluster.local" | head -1)
echo "$srv" | grep -q " 80 " && ok "SRV returns port 80: $srv" || no "unexpected SRV answer: '${srv:-nothing}'"

echo "== 7. A missing name is NXDOMAIN, not a timeout (24.6) =="
st=$(D dig "nosuchthing.${NS}.svc.cluster.local" 2>/dev/null | grep -o 'status: [A-Z]*' | head -1)
[ "$st" = "status: NXDOMAIN" ] && ok "$st -- the whole path works" \
                              || no "got '${st:-no answer}', expected NXDOMAIN"

echo "== 8. hostNetwork and dnsPolicy (24.5) =="
if kubectl get pod hostnet-broken -n $NS >/dev/null 2>&1; then
  b=$(kubectl exec -n $NS hostnet-broken -- dig +short kubernetes.default.svc.cluster.local 2>/dev/null | head -1)
  [ -z "$b" ] && ok "hostnet-broken cannot resolve Services (the trap)" \
              || no "hostnet-broken resolved '$b' -- unexpected"
else
  echo "  SKIP  hostnet-broken not applied"
fi
if kubectl get pod hostnet-fixed -n $NS >/dev/null 2>&1; then
  f=$(kubectl exec -n $NS hostnet-fixed -- dig +short kubernetes.default.svc.cluster.local 2>/dev/null | head -1)
  [ -n "$f" ] && ok "hostnet-fixed resolves Services -> $f" \
              || no "hostnet-fixed still cannot resolve -- is dnsPolicy set?"
else
  echo "  SKIP  hostnet-fixed not applied"
fi

echo "== 9. The Corefile is intact =="
cf=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)
echo "$cf" | grep -q "kubernetes cluster.local" && ok "the kubernetes plugin is configured" \
                                                || no "no 'kubernetes cluster.local' line"
echo "$cf" | grep -q "forward" && ok "  a forward plugin is present" || no "  no forward plugin"
if echo "$cf" | grep -q "hosts {"; then
  echo "$cf" | grep -A3 "hosts {" | grep -q fallthrough \
    && ok "  a hosts block is present AND has fallthrough" \
    || no "  a hosts block WITHOUT fallthrough -- this breaks cluster DNS (C4)"
else
  ok "  no leftover hosts block"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
