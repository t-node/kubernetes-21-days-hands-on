#!/usr/bin/env bash
# CKA 19 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Run it BEFORE step 9 (deleting the CRD), or everything below will be missing.
NS=cka19
CRD=flighttickets.flights.example.com
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. The CRD =="
if kubectl get crd $CRD >/dev/null 2>&1; then
  ok "$CRD exists"
  est=$(kubectl get crd $CRD -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
  [ "$est" = "True" ] && ok "  Established=True" || no "  Established=${est:-unknown}"
  sc=$(kubectl get crd $CRD -o jsonpath='{.spec.scope}')
  [ "$sc" = "Namespaced" ] && ok "  scope=Namespaced" || no "  scope=$sc"
  sn=$(kubectl get crd $CRD -o jsonpath='{.spec.names.shortNames[0]}')
  [ "$sn" = "ft" ] && ok "  shortName=ft" || no "  shortName=${sn:-none}"
  st=$(kubectl get crd $CRD -o jsonpath='{range .spec.versions[*]}{.name}={.storage} {end}')
  echo "        versions: $st"
  n=$(kubectl get crd $CRD -o jsonpath='{.spec.versions[?(@.storage==true)].name}' | wc -w)
  [ "$n" = "1" ] && ok "  exactly one storage version" || no "  $n storage versions"
  kubectl get crd $CRD -o jsonpath='{.spec.versions[0].subresources.status}' 2>/dev/null | grep -q '{}' \
    && ok "  the status subresource is enabled" || no "  no status subresource"
else
  no "$CRD not found -- apply solution/01-crd.yaml"
  echo; echo "== 0 passed, 1 failed =="; exit 1
fi

echo "== 2. Schema enforcement =="
out=$(kubectl apply -f "$(dirname "$0")/03-ticket-invalid-BAD.yaml" 2>&1)
echo "$out" | grep -q "Invalid value: 42" && ok "maximum on spec.number is enforced" \
                                          || no "the out-of-range value was not rejected"
echo "$out" | grep -qi "Unsupported value" && ok "the class enum is enforced" \
                                           || no "the enum was not enforced"

kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: flights.example.com/v1
kind: FlightTicket
metadata: {name: verify-defaults, namespace: $NS}
spec: {from: Delhi, to: Dubai}
EOF
d=$(kubectl get ft verify-defaults -n $NS -o jsonpath='{.spec.number}/{.spec.class}' 2>/dev/null)
[ "$d" = "1/economy" ] && ok "defaults applied: number=1, class=economy" || no "defaults are '${d:-missing}'"
kubectl delete ft verify-defaults -n $NS >/dev/null 2>&1

echo "== 3. Status is not writable by apply =="
kubectl patch ft mumbai-london -n $NS --type=merge -p '{"status":{"state":"Hacked"}}' >/dev/null 2>&1
s=$(kubectl get ft mumbai-london -n $NS -o jsonpath='{.status.state}' 2>/dev/null)
[ "$s" != "Hacked" ] && ok "a normal patch did not write status (got '${s:-empty}')" \
                     || no "status was written through the main resource"

echo "== 4. The controller =="
r=$(kubectl get deploy flight-controller -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${r:-0}" -ge 1 ] 2>/dev/null && ok "flight-controller is Running" || no "flight-controller not ready (${r:-0})"

for res in flighttickets flighttickets/status; do
  kubectl auth can-i get "$res" --as=system:serviceaccount:$NS:flight-controller >/dev/null 2>&1 \
    && ok "  the controller may access $res" || no "  the controller cannot access $res"
done

tot=$(kubectl get ft -n $NS --no-headers 2>/dev/null | wc -l)
booked=$(kubectl get ft -n $NS -o jsonpath='{range .items[*]}{.status.confirmation}{"\n"}{end}' 2>/dev/null | grep -c "^BK-")
if [ "${tot:-0}" -gt 0 ]; then
  [ "$booked" = "$tot" ] && ok "all $tot ticket(s) have a booking confirmation" \
                         || no "$booked of $tot tickets booked -- give the controller a few more seconds"
else
  no "no FlightTickets exist -- apply solution/02-ticket.yaml"
fi

echo "== 5. Idempotency =="
c1=$(kubectl get ft mumbai-london -n $NS -o jsonpath='{.status.confirmation}' 2>/dev/null)
sleep 8
c2=$(kubectl get ft mumbai-london -n $NS -o jsonpath='{.status.confirmation}' 2>/dev/null)
[ -n "$c1" ] && [ "$c1" = "$c2" ] && ok "the confirmation is stable across reconciles ($c1)" \
                                  || no "the confirmation changed: '$c1' -> '$c2'"

echo "== 6. Ownership and garbage collection =="
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: flights.example.com/v1
kind: FlightTicket
metadata: {name: gc-probe, namespace: $NS}
spec: {from: Osaka, to: Busan}
EOF
sleep 10
own=$(kubectl get cm booking-gc-probe -n $NS -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
[ "$own" = "FlightTicket" ] && ok "the child ConfigMap is owned by its FlightTicket" \
                            || no "no owner reference on booking-gc-probe (got '${own:-nothing}')"
kubectl delete ft gc-probe -n $NS >/dev/null 2>&1
sleep 8
if kubectl get cm booking-gc-probe -n $NS >/dev/null 2>&1; then
  no "the ConfigMap survived its owner -- garbage collection did not fire"
else
  ok "deleting the ticket removed its ConfigMap automatically"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
