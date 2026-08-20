#!/usr/bin/env bash
# Install Calico on the netpol-lab cluster so NetworkPolicy is actually enforced.
#
#   bash solution/install-calico.sh
#   CALICO_VERSION=v3.29.0 bash solution/install-calico.sh    # override
#
# Until this runs, every pod on that cluster stays Pending or NotReady -- there
# is no CNI at all. That is expected, and it is worth seeing once.
set -euo pipefail
CALICO_VERSION=${CALICO_VERSION:-v3.28.2}
CTX=${CTX:-kind-netpol-lab}
URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

kubectl config get-contexts -o name | grep -qx "$CTX" || {
  echo "no context '$CTX'. Create the cluster first:"
  echo "   kind create cluster --name netpol-lab --config solution/kind-calico.yaml"
  exit 1
}

echo "==> nodes before Calico (expect NotReady -- there is no CNI)"
kubectl --context="$CTX" get nodes

echo "==> applying Calico ${CALICO_VERSION}"
kubectl --context="$CTX" apply -f "$URL"

echo "==> waiting for the calico-node DaemonSet"
kubectl --context="$CTX" -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl --context="$CTX" -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s

echo "==> waiting for every node to become Ready"
kubectl --context="$CTX" wait --for=condition=Ready nodes --all --timeout=300s
kubectl --context="$CTX" get nodes

echo
echo "Calico is up. NetworkPolicy is now enforced on this cluster."
echo "Switch to it with:  kubectl config use-context ${CTX}"
