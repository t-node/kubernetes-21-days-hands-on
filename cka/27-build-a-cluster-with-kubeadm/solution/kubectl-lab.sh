#!/usr/bin/env bash
# Run kubectl against the kubeadm lab cluster, from inside the control-plane
# node -- the simplest way to reach an API server on a private Docker network.
#
#   bash solution/kubectl-lab.sh get nodes
#   bash solution/kubectl-lab.sh -n kube-system get pods
set -uo pipefail
CP=${CP:-kubeadm-cp}
docker exec "$CP" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"
