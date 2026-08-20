#!/usr/bin/env bash
# Break the cluster in one of eight ways, WITHOUT telling you which.
#
#   bash solution/break.sh <1-8>      apply a scenario
#   bash solution/break.sh random     apply one at random, and do not print it
#   bash solution/break.sh list       how many scenarios exist (not what they are)
#   bash solution/restore.sh          undo whatever is broken
#
# What it did is recorded in solution/.broken so restore.sh works even if you
# forget. Do not read that file until you have finished diagnosing.
set -uo pipefail
NS=cka31
CP=${CP:-devops-control-plane}
WK=${WK:-devops-worker2}
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${HERE}/.broken"

need_app() {
  kubectl get ns "$NS" >/dev/null 2>&1 || {
    echo "the application is not deployed. Run first:"
    echo "   kubectl apply -f solution/app.yaml"
    exit 1; }
}

record() { echo "$1" >> "$STATE"; }

backup_manifests() {
  docker exec "$CP" test -d /root/ts-manifests.backup 2>/dev/null \
    || docker exec "$CP" cp -r /etc/kubernetes/manifests /root/ts-manifests.backup
}

scenario() {
case "$1" in
  1)
    # --- application: the Service selector no longer matches the pods
    kubectl patch svc web -n $NS -p '{"spec":{"selector":{"app":"web-frontend"}}}' >/dev/null
    record "1"
    ;;
  2)
    # --- application: targetPort names a port the container does not expose
    kubectl patch svc web -n $NS --type=json \
      -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"https"}]' >/dev/null
    record "2"
    ;;
  3)
    # --- application: an image tag that does not exist
    kubectl set image deployment/db -n $NS db=nginx:1.27-alpine-nonexistent >/dev/null
    record "3"
    ;;
  4)
    # --- control plane: the scheduler cannot start
    backup_manifests
    docker exec "$CP" sed -i 's|--kubeconfig=/etc/kubernetes/scheduler.conf|--kubeconfig=/etc/kubernetes/scheduler-typo.conf|' \
      /etc/kubernetes/manifests/kube-scheduler.yaml
    record "4"
    ;;
  5)
    # --- control plane: the controller manager cannot start
    backup_manifests
    docker exec "$CP" sed -i 's|--kubeconfig=/etc/kubernetes/controller-manager.conf|--kubeconfig=/etc/kubernetes/cm-typo.conf|' \
      /etc/kubernetes/manifests/kube-controller-manager.yaml
    record "5"
    ;;
  6)
    # --- worker node: the kubelet is stopped
    docker exec "$WK" systemctl stop kubelet 2>/dev/null \
      || docker exec "$WK" pkill -f "/usr/bin/kubelet" 2>/dev/null
    record "6"
    ;;
  7)
    # --- worker node: cordoned, plus a taint nothing tolerates
    kubectl cordon "$WK" >/dev/null 2>&1
    kubectl taint node "$WK" maintenance=inprogress:NoSchedule --overwrite >/dev/null 2>&1
    record "7"
    ;;
  8)
    # --- networking: cluster DNS has no backends
    kubectl -n kube-system scale deployment coredns --replicas=0 >/dev/null
    record "8"
    ;;
  *)
    echo "unknown scenario '$1' (valid: 1-8)"; exit 1 ;;
esac
}

case "${1:-}" in
  list)
    echo "8 scenarios exist. They are not described here on purpose."
    echo "Apply one with:  bash solution/break.sh <1-8>"
    echo "Or blind:        bash solution/break.sh random"
    exit 0 ;;
  random)
    need_app
    n=$(( ( $(date +%s) % 8 ) + 1 ))
    scenario "$n" >/dev/null 2>&1
    echo "A fault has been introduced. It is not printed."
    echo
    echo "Something in the cluster is wrong. Start with:"
    echo "   kubectl get nodes"
    echo "   kubectl -n kube-system get pods"
    echo "   kubectl get pods -n ${NS}"
    echo
    echo "Undo it with:  bash solution/restore.sh"
    exit 0 ;;
  ""|-h|--help)
    echo "usage: $0 <1-8|random|list>"; exit 1 ;;
esac

need_app
scenario "$1"
echo "Scenario $1 applied. What it did is NOT printed."
echo
echo "The application should be reachable with:"
echo "   kubectl exec -n ${NS} client -- curl -s -m5 -o /dev/null -w '%{http_code}\n' http://web"
echo
echo "Give it 30-60 seconds to take effect, then diagnose."
echo "Undo with:  bash solution/restore.sh"
