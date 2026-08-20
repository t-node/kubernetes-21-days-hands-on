#!/usr/bin/env bash
# Install a CNI so the node can go Ready (27.1, CKA 22).
#
#   bash solution/install-cni.sh              # Flannel, from the internet
#   bash solution/install-cni.sh manual       # hand-written CNI config, no internet
#
# The `manual` mode is the CKA 22 exercise applied for real: write a bridge
# conflist per node with that node's podCIDR, and add a route to the other
# node's CIDR. It is what a CNI plugin does, done by hand.
set -uo pipefail
CP=${CP:-kubeadm-cp}
WK=${WK:-kubeadm-wk}
NET=${NET:-kubeadm-lab}
MODE=${1:-flannel}
K() { docker exec "$CP" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"; }

case "$MODE" in
  flannel)
    echo "==> installing Flannel (its default pod CIDR is 10.244.0.0/16,"
    echo "    which is what kubeadm-init.sh passed to --pod-network-cidr)"
    docker exec "$CP" kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
      https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml \
      || { echo "!! could not fetch the manifest -- try: bash $0 manual"; exit 1; }
    echo
    echo "==> waiting for the DaemonSet"
    K -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s
    ;;

  manual)
    echo "==> writing a bridge CNI config on each node, by hand (CKA 22)"
    for n in "$CP" "$WK"; do
      NODECIDR=$(K get node "$n" -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
      if [ -z "$NODECIDR" ]; then
        echo "    $n has no spec.podCIDR yet -- has it joined?"; continue
      fi
      GW="${NODECIDR%.*}.1"
      echo "    $n  podCIDR=$NODECIDR  bridge gateway=$GW"
      docker exec "$n" sh -c "mkdir -p /etc/cni/net.d && cat > /etc/cni/net.d/10-mybridge.conflist <<EOF
{
  \"cniVersion\": \"0.4.0\",
  \"name\": \"mybridge\",
  \"plugins\": [
    {
      \"type\": \"bridge\",
      \"bridge\": \"cni0\",
      \"isGateway\": true,
      \"ipMasq\": true,
      \"ipam\": {
        \"type\": \"host-local\",
        \"subnet\": \"${NODECIDR}\",
        \"routes\": [ { \"dst\": \"0.0.0.0/0\" } ]
      }
    },
    { \"type\": \"portmap\", \"capabilities\": { \"portMappings\": true } }
  ]
}
EOF"
    done

    echo "==> adding a route on each node to the OTHER node's pod CIDR (CKA 21)"
    for a in "$CP" "$WK"; do
      for b in "$CP" "$WK"; do
        [ "$a" = "$b" ] && continue
        BC=$(K get node "$b" -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
        BIP=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$NET\").IPAddress }}" "$b")
        [ -n "$BC" ] && docker exec "$a" ip route replace "$BC" via "$BIP" \
          && echo "    on $a: $BC via $BIP"
      done
    done
    ;;

  *) echo "usage: $0 [flannel|manual]"; exit 1 ;;
esac

echo
echo "==> waiting for the nodes to go Ready"
for i in $(seq 1 60); do
  notready=$(K get nodes --no-headers 2>/dev/null | grep -c "NotReady")
  [ "${notready:-1}" = "0" ] && { echo "    all Ready"; break; }
  sleep 5
done
K get nodes -o wide
K -n kube-system get pods
