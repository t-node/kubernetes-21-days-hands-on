#!/usr/bin/env bash
# CKA 13 verification. Run from the assignment directory:
#   bash solution/verify.sh
CP=${CP:-devops-control-plane}
OUT=${OUT:-/tmp/cka13}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

x509() { docker exec "$CP" openssl x509 -in "$1" -noout "$2" 2>/dev/null | sed 's/^[^=]*=//' | sed 's/^ *//'; }

echo "== 1. The control plane is healthy =="
kubectl get --raw=/readyz >/dev/null 2>&1 && ok "the API server answers /readyz" \
                                          || no "the API server is not ready -- run: bash solution/restore.sh"

echo "== 2. Two distinct certificate authorities =="
kca=$(x509 /etc/kubernetes/pki/ca.crt -subject)
eca=$(x509 /etc/kubernetes/pki/etcd/ca.crt -subject)
[ -n "$kca" ] && ok "pki/ca.crt subject = $kca"           || no "pki/ca.crt unreadable"
[ -n "$eca" ] && ok "pki/etcd/ca.crt subject = $eca"      || no "pki/etcd/ca.crt unreadable"
[ -n "$kca" ] && [ "$kca" != "$eca" ] && ok "they are DIFFERENT authorities" \
                                      || no "the two CA files have the same subject"

echo "== 3. Every certificate is signed by one of them =="
kcn=$(echo "$kca" | grep -o 'CN *= *.*' | sed 's/CN *= *//')
ecn=$(echo "$eca" | grep -o 'CN *= *.*' | sed 's/CN *= *//')
bad=0
for f in $(docker exec "$CP" sh -c 'ls /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt 2>/dev/null'); do
  iss=$(x509 "$f" -issuer | grep -o 'CN *= *.*' | sed 's/CN *= *//')
  case "$iss" in
    "$kcn"|"$ecn"|"front-proxy-ca") ;;
    *) echo "        unexpected issuer '$iss' on ${f#/etc/kubernetes/}"; bad=$((bad+1)) ;;
  esac
done
[ "$bad" -eq 0 ] && ok "no certificate has an unrecognised issuer" \
                 || no "$bad certificate(s) signed by something else -- see above"

echo "== 4. The API server points at the right etcd CA =="
ecafile=$(docker exec "$CP" grep -o -- '--etcd-cafile=[^ ]*' \
          /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | cut -d= -f2)
case "$ecafile" in
  */pki/etcd/ca.crt) ok "--etcd-cafile = $ecafile" ;;
  "")  no "--etcd-cafile not found in the manifest" ;;
  *)   no "--etcd-cafile = $ecafile -- that is the WRONG CA (see 13.5)" ;;
esac

clientca=$(docker exec "$CP" grep -o -- '--client-ca-file=[^ ]*' \
           /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | cut -d= -f2)
case "$clientca" in
  */pki/ca.crt) ok "--client-ca-file = $clientca" ;;
  *) no "--client-ca-file = ${clientca:-missing}" ;;
esac

echo "== 5. The API server certificate covers the expected names =="
sans=$(docker exec "$CP" openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
       -noout -ext subjectAltName 2>/dev/null)
for want in kubernetes.default.svc kubernetes.default 10.96.0.1; do
  echo "$sans" | grep -q "$want" && ok "  SAN contains $want" || no "  SAN is missing $want"
done

echo "== 6. Certificate expiry =="
if docker exec "$CP" kubeadm certs check-expiration >/dev/null 2>&1; then
  ok "kubeadm certs check-expiration runs"
  docker exec "$CP" kubeadm certs check-expiration 2>/dev/null \
    | awk 'NR>1 && /invalid|expired/ {print "        " $0}' | head -5
else
  no "kubeadm certs check-expiration failed on $CP"
fi

echo "== 7. The certificate you issued in part C =="
if [ -f "${OUT}/dev-alice.crt" ]; then
  s=$(openssl x509 -in "${OUT}/dev-alice.crt" -noout -subject 2>/dev/null)
  i=$(openssl x509 -in "${OUT}/dev-alice.crt" -noout -issuer 2>/dev/null)
  echo "$s" | grep -q "CN *= *dev-alice"  && ok "CN is dev-alice"   || no "unexpected subject: $s"
  echo "$s" | grep -q "O *= *developers"  && ok "O is developers"   || no "no O=developers in: $s"
  echo "$i" | grep -q "CN *= *${kcn}"     && ok "signed by the cluster CA ($kcn)" \
                                          || no "issuer is not the cluster CA: $i"
else
  echo "  SKIP  ${OUT}/dev-alice.crt not found -- part C not run"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
