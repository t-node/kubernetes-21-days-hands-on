#!/usr/bin/env bash
# Remove everything lab-up.sh created.
#
#   bash solution/lab-down.sh
set -uo pipefail
NET=${NET:-kubeadm-lab}
for n in ${CP:-kubeadm-cp} ${WK:-kubeadm-wk}; do
  docker rm -f "$n" >/dev/null 2>&1 && echo "removed $n"
done
docker network rm "$NET" >/dev/null 2>&1 && echo "removed network $NET"
rm -f "${HOME}/.kube/kubeadm-lab.conf" 2>/dev/null
echo "done"
