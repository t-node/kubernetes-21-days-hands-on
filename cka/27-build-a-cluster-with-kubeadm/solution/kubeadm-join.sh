#!/usr/bin/env bash
# Join the worker, using a token created on the control plane (27.4).
#
#   bash solution/kubeadm-join.sh
#   bash solution/kubeadm-join.sh reset      # kubeadm reset + the cleanup it does not do
set -uo pipefail
CP=${CP:-kubeadm-cp}
WK=${WK:-kubeadm-wk}
K() { docker exec "$CP" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"; }

case "${1:-join}" in
  join)
    echo "=== 1. tokens currently valid on the control plane"
    docker exec "$CP" kubeadm token list 2>/dev/null || echo "   (none -- they expire after 24h)"

    echo
    echo "=== 2. create one and print the whole join command"
    JOIN=$(docker exec "$CP" kubeadm token create --print-join-command 2>/dev/null)
    [ -n "$JOIN" ] || { echo "!! could not create a token -- is the control plane up?"; exit 1; }
    echo "   $JOIN"

    echo
    echo "=== 3. the CA hash in that command, computed independently (27.4)"
    docker exec "$CP" sh -c "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
      | openssl rsa -pubin -outform der 2>/dev/null \
      | openssl dgst -sha256 -hex | sed 's/^.* //'"
    echo "   compare with the --discovery-token-ca-cert-hash above"

    echo
    echo "=== 4. joining $WK"
    docker exec "$WK" sh -c "$JOIN --ignore-preflight-errors=all" 2>&1 | tail -20
    rc=$?
    [ "$rc" = "0" ] || { echo "!! join failed; try: docker exec $WK journalctl -u kubelet --no-pager | tail -30"; exit 1; }

    echo
    echo "=== 5. what the join produced"
    sleep 5
    K get nodes -o wide
    echo
    echo "-- the kubelet's client certificate, issued during the join (27.4):"
    docker exec "$WK" sh -c "grep client-certificate /etc/kubernetes/kubelet.conf" 2>/dev/null \
      || docker exec "$WK" sh -c "ls -l /var/lib/kubelet/pki/"
    docker exec "$WK" sh -c "openssl x509 -in \$(ls /var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null) -noout -subject 2>/dev/null" \
      || echo "   (look in /var/lib/kubelet/pki/)"
    echo
    echo "   CN=system:node:${WK} and O=system:nodes -- exactly what CKA 13 predicted."
    echo
    echo "-- the CSR that produced it:"
    K get csr 2>/dev/null | head -5
    ;;

  reset)
    echo "=== 1. drain and delete from the API side (27.5)"
    K drain "$WK" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>&1 | tail -3
    K delete node "$WK" 2>&1 | tail -1

    echo
    echo "=== 2. kubeadm reset ON the machine -- deleting the Node object did not touch it"
    docker exec "$WK" kubeadm reset -f 2>&1 | tail -12

    echo
    echo "=== 3. the cleanup kubeadm reset does NOT do (27.5)"
    docker exec "$WK" sh -c '
      rm -rf /etc/cni/net.d
      iptables -F 2>/dev/null; iptables -t nat -F 2>/dev/null
      iptables -t mangle -F 2>/dev/null; iptables -X 2>/dev/null
      rm -rf /root/.kube
      echo "   removed /etc/cni/net.d, flushed iptables, removed /root/.kube"'

    echo
    echo "=== 4. the node is gone from the cluster and the machine is clean"
    K get nodes
    docker exec "$WK" sh -c "ls /etc/kubernetes 2>&1 | head -3"
    ;;

  *) echo "usage: $0 [join|reset]"; exit 1 ;;
esac
