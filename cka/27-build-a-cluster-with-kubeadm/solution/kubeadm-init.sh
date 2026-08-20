#!/usr/bin/env bash
# Run kubeadm init on the control-plane machine, exactly as you would on a VM.
#
#   bash solution/kubeadm-init.sh
#
# It prints every command before running it, so you can follow along -- and so
# you can run them by hand instead if you would rather.
set -uo pipefail
CP=${CP:-kubeadm-cp}
NET=${NET:-kubeadm-lab}
POD_CIDR=${POD_CIDR:-10.244.0.0/16}
KCFG="${HOME}/.kube/kubeadm-lab.conf"

run() { echo; echo "\$ $*"; docker exec "$CP" sh -c "$*"; }

CPIP=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$NET\").IPAddress }}" "$CP" 2>/dev/null)
[ -n "$CPIP" ] || { echo "cannot find $CP -- run lab-up.sh first"; exit 1; }
echo "control-plane address: $CPIP"

echo
echo "=== 0. proof there is no cluster here yet"
run "ls /etc/kubernetes 2>&1 | head -3"
run "crictl ps 2>/dev/null | head -3"

echo
echo "=== 1. what kubeadm would do, before doing it (27.3)"
run "kubeadm init phase --help 2>&1 | sed -n '/Available Commands/,/^$/p'"

echo
echo "=== 2. the defaults it starts from"
run "kubeadm config print init-defaults 2>/dev/null | head -30"

echo
echo "=== 3. kubeadm init"
echo "    --pod-network-cidr must match the CNI's configuration (27.3)"
echo "    --ignore-preflight-errors=all because these machines are containers;"
echo "    on a real VM you would fix the preflight failures instead."
docker exec "$CP" kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --apiserver-advertise-address="$CPIP" \
  --ignore-preflight-errors=all \
  2>&1 | tee /tmp/kubeadm-init.log
rc=${PIPESTATUS[0]}
if [ "$rc" != "0" ]; then
  echo
  echo "!! kubeadm init failed. Look at the last lines above, then:"
  echo "   docker exec $CP journalctl -u kubelet --no-pager | tail -40"
  echo "   docker exec $CP crictl ps -a"
  exit 1
fi

echo
echo "=== 4. take the kubeconfig off the node (27.3, the kubeconfig phase)"
mkdir -p "${HOME}/.kube"
docker cp "${CP}:/etc/kubernetes/admin.conf" "$KCFG" >/dev/null
# The file points at the container's own address, which is reachable from the
# Docker network but not necessarily from here; publish a host port instead.
docker exec "$CP" sh -c "cat /etc/kubernetes/admin.conf" > "$KCFG"
export KUBECONFIG="$KCFG"
echo "    wrote $KCFG"
echo
echo "    NOTE: that kubeconfig points at ${CPIP}:6443, which is on the"
echo "    ${NET} Docker network. Use kubectl from inside the node:"
echo "        docker exec $CP kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes"
echo "    ...or run:  bash solution/kubectl-lab.sh get nodes"

echo
echo "=== 5. the state kubeadm leaves you in"
run "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes"
run "kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system"
echo
echo "    NotReady, and CoreDNS Pending. That is CORRECT (27.1): the control"
echo "    plane is complete and no CNI has been chosen. Nothing is broken."

echo
echo "=== 6. the join command, for the worker (27.4)"
docker exec "$CP" kubeadm token create --print-join-command 2>/dev/null | tee /tmp/kubeadm-join.cmd

echo
echo "Next:  bash solution/install-cni.sh   then   bash solution/kubeadm-join.sh"
