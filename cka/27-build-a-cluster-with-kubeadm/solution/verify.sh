#!/usr/bin/env bash
# CKA 27 verification. Run from the assignment directory, after Part B:
#   bash solution/verify.sh
CP=${CP:-kubeadm-cp}
WK=${WK:-kubeadm-wk}
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
K() { docker exec "$CP" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@" 2>/dev/null; }

echo "== 0. The machines =="
for n in "$CP" "$WK"; do
  docker inspect "$n" >/dev/null 2>&1 && ok "$n exists" || {
    no "$n missing -- run solution/lab-up.sh"; }
done
docker exec "$CP" sh -c 'ps -p 1 -o comm=' 2>/dev/null | grep -q systemd \
  && ok "PID 1 on $CP is systemd" || no "PID 1 is not systemd"

if ! K get nodes >/dev/null 2>&1; then
  no "the API server is not answering -- has kubeadm-init.sh run?"
  echo; echo "== $pass passed, $((fail)) failed =="; exit 1
fi

echo "== 1. What kubeadm init produced (27.3) =="
for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
  docker exec "$CP" test -f "/etc/kubernetes/manifests/$f" \
    && ok "  manifests/$f" || no "  manifests/$f missing"
done
for f in ca.crt ca.key apiserver.crt etcd/ca.crt; do
  docker exec "$CP" test -f "/etc/kubernetes/pki/$f" \
    && ok "  pki/$f" || no "  pki/$f missing"
done
for f in admin.conf kubelet.conf scheduler.conf controller-manager.conf; do
  docker exec "$CP" test -f "/etc/kubernetes/$f" \
    && ok "  $f" || no "  $f missing"
done

echo "== 2. Two distinct CAs (CKA 13) =="
k=$(docker exec "$CP" openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject 2>/dev/null)
e=$(docker exec "$CP" openssl x509 -in /etc/kubernetes/pki/etcd/ca.crt -noout -subject 2>/dev/null)
[ -n "$k" ] && [ "$k" != "$e" ] && ok "the cluster CA and the etcd CA differ" \
                                || no "could not read both CAs, or they are identical"
echo "        $k"
echo "        $e"

echo "== 3. kubeadm-config records what you passed (27.3) =="
cfg=$(K -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}')
echo "$cfg" | grep -q "podSubnet" && ok "podSubnet is recorded: $(echo "$cfg" | grep podSubnet | tr -d ' ')" \
                                  || no "no podSubnet in kubeadm-config"
echo "$cfg" | grep -q "serviceSubnet" && ok "serviceSubnet is recorded" || no "no serviceSubnet"

echo "== 4. Both nodes joined and are Ready =="
n=$(K get nodes --no-headers | wc -l)
[ "${n:-0}" -ge 1 ] 2>/dev/null && ok "$n node(s) in the cluster" || no "no nodes"
nr=$(K get nodes --no-headers | grep -c "NotReady")
[ "${nr:-1}" = "0" ] && ok "  none are NotReady (a CNI is installed)" \
                     || no "  ${nr} node(s) NotReady -- run solution/install-cni.sh"
for node in $(K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  c=$(K get node "$node" -o jsonpath='{.spec.podCIDR}')
  [ -n "$c" ] && ok "  $node has podCIDR $c" || no "  $node has no podCIDR"
done

echo "== 5. The control plane is running (27.1) =="
for c in kube-apiserver kube-scheduler kube-controller-manager etcd; do
  r=$(K -n kube-system get pods -l component=$c --no-headers | grep -c Running)
  [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "  $c Running" || no "  $c not Running"
done
cd_=$(K -n kube-system get pods -l k8s-app=kube-dns --no-headers | grep -c Running)
[ "${cd_:-0}" -ge 1 ] 2>/dev/null && ok "  CoreDNS Running (it was Pending before the CNI)" \
                                  || no "  CoreDNS not Running"

echo "== 6. The worker's identity came from a CSR (27.4) =="
if K get node "$WK" >/dev/null 2>&1; then
  ok "$WK is a member of the cluster"
  subj=$(docker exec "$WK" sh -c \
    'openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject' 2>/dev/null)
  echo "        $subj"
  echo "$subj" | grep -q "CN *= *system:node:${WK}" && ok "  CN = system:node:${WK}" \
                                                    || no "  unexpected CN"
  echo "$subj" | grep -q "O *= *system:nodes" && ok "  O = system:nodes" || no "  no O=system:nodes"
  csr=$(K get csr --no-headers 2>/dev/null | wc -l)
  [ "${csr:-0}" -ge 1 ] 2>/dev/null && ok "  $csr CertificateSigningRequest(s) recorded" \
                                    || echo "  NOTE  no CSRs listed (they are garbage-collected after an hour)"
else
  echo "  SKIP  $WK has not joined (or was reset)"
fi

echo "== 7. It actually works =="
K delete deployment verify-web >/dev/null 2>&1
K create deployment verify-web --image=nginx:alpine --replicas=2 >/dev/null 2>&1
if K rollout status deployment/verify-web --timeout=120s >/dev/null 2>&1; then
  ok "a Deployment scheduled and became available"
  K get pods -l app=verify-web -o wide --no-headers | sed 's/^/        /'
else
  no "the Deployment did not become available -- check pod events"
  K get pods -l app=verify-web 2>/dev/null | sed 's/^/        /'
fi
K delete deployment verify-web >/dev/null 2>&1

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
