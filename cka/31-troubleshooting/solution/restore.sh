#!/usr/bin/env bash
# Undo everything break.sh did.
#
#   bash solution/restore.sh          undo what is recorded in .broken
#   bash solution/restore.sh all      undo every scenario unconditionally
#
# `all` is the safety net for a cluster left in an unknown state -- it is
# idempotent, so running it when nothing is broken does nothing.
set -uo pipefail
NS=cka31
CP=${CP:-devops-control-plane}
WK=${WK:-devops-worker2}
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${HERE}/.broken"

undo() {
case "$1" in
  1) kubectl patch svc web -n $NS -p '{"spec":{"selector":{"app":"web"}}}' >/dev/null 2>&1 \
       && echo "   1: Service selector restored" ;;
  2) kubectl patch svc web -n $NS --type=json \
       -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]' >/dev/null 2>&1 \
       && echo "   2: targetPort restored" ;;
  3) kubectl set image deployment/db -n $NS db=nginx:1.27-alpine >/dev/null 2>&1 \
       && echo "   3: image restored" ;;
  4) docker exec "$CP" sed -i 's|scheduler-typo.conf|scheduler.conf|' \
       /etc/kubernetes/manifests/kube-scheduler.yaml 2>/dev/null \
       && echo "   4: scheduler manifest restored" ;;
  5) docker exec "$CP" sed -i 's|cm-typo.conf|controller-manager.conf|' \
       /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null \
       && echo "   5: controller-manager manifest restored" ;;
  6) docker exec "$WK" systemctl start kubelet 2>/dev/null \
       && echo "   6: kubelet started" ;;
  7) kubectl uncordon "$WK" >/dev/null 2>&1
     kubectl taint node "$WK" maintenance- >/dev/null 2>&1
     echo "   7: node uncordoned and untainted" ;;
  8) kubectl -n kube-system scale deployment coredns --replicas=2 >/dev/null 2>&1 \
       && echo "   8: CoreDNS scaled back to 2" ;;
esac
}

echo "==> restoring"
if [ "${1:-}" = "all" ] || [ ! -f "$STATE" ]; then
  for n in 1 2 3 4 5 6 7 8; do undo "$n"; done
else
  while read -r n; do [ -n "$n" ] && undo "$n"; done < "$STATE"
fi
rm -f "$STATE"

echo
echo "==> waiting for the cluster to settle"
for i in $(seq 1 40); do
  nodes_bad=$(kubectl get nodes --no-headers 2>/dev/null | grep -cE "NotReady|SchedulingDisabled")
  cp_bad=$(kubectl -n kube-system get pods --no-headers 2>/dev/null | grep -vc "Running\|Completed")
  if [ "${nodes_bad:-1}" = "0" ] && [ "${cp_bad:-1}" = "0" ]; then break; fi
  sleep 3
done

echo
kubectl get nodes 2>/dev/null
echo
kubectl -n kube-system get pods 2>/dev/null | grep -E "scheduler|controller|coredns"
echo
kubectl get pods -n $NS 2>/dev/null
echo
echo "==> end-to-end check"
kubectl exec -n $NS client -- curl -s -m5 -o /dev/null -w "   web -> %{http_code}\n" http://web 2>/dev/null \
  || echo "   the client pod is not ready yet; retry in a moment"
