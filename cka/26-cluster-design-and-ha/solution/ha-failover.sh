#!/usr/bin/env bash
# Take control-plane nodes down, one at a time, and watch what happens.
#
#   bash solution/ha-failover.sh status        # where we are now
#   bash solution/ha-failover.sh kill 2        # stop control-plane 2  (3 -> 2: still quorum)
#   bash solution/ha-failover.sh kill 3        # stop control-plane 3  (2 -> 1: QUORUM LOST)
#   bash solution/ha-failover.sh restore       # start everything again
#
# This deliberately breaks the cluster at the second step. That is the point --
# reading a quorum failure is a skill, and it is unmistakable once seen.
set -uo pipefail
CTX=${CTX:-kind-ha-lab}
PREFIX="${CTX#kind-}"
K="kubectl --context=$CTX"

cps() { docker ps -a --filter "name=${PREFIX}-control-plane" --format '{{.Names}}' | sort; }

node_for() {  # node_for <n>  -> container name; 1 == the un-suffixed one
  if [ "$1" = "1" ]; then echo "${PREFIX}-control-plane"; else echo "${PREFIX}-control-plane$1"; fi
}

status() {
  echo "-- containers:"
  docker ps -a --filter "name=${PREFIX}-control-plane" \
    --format '   {{.Names}}  {{.State}}' | sort
  echo
  echo "-- can we still talk to the API?"
  if timeout 15 $K get nodes >/dev/null 2>&1; then
    echo "   YES"
    $K get nodes 2>/dev/null | sed 's/^/   /'
    echo
    echo "-- lease holders right now:"
    for l in kube-scheduler kube-controller-manager; do
      printf "   %-26s %s\n" "$l" "$($K -n kube-system get lease "$l" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)"
    done
  else
    echo "   NO -- the API server is not answering."
    echo "   With etcd below quorum this is expected: no writes, and reads fail"
    echo "   because the API server cannot serve from a cluster with no leader."
  fi
}

case "${1:-status}" in
  status) status ;;

  kill)
    N=${2:-2}
    NODE=$(node_for "$N")
    echo "==> stopping $NODE"
    docker stop "$NODE" >/dev/null || { echo "no such container"; exit 1; }
    running=$(docker ps --filter "name=${PREFIX}-control-plane" --format '{{.Names}}' | wc -l)
    total=$(cps | wc -l)
    quorum=$(( total / 2 + 1 ))
    echo "    control planes running: ${running} of ${total};  quorum needs ${quorum}"
    if [ "$running" -ge "$quorum" ]; then
      echo "    QUORUM HELD -- the cluster should keep working."
    else
      echo "    QUORUM LOST -- expect the API server to stop answering."
    fi
    echo
    echo "-- giving leader election up to 30s to settle..."
    sleep 30
    status
    ;;

  restore)
    echo "==> starting every control-plane container"
    for c in $(cps); do docker start "$c" >/dev/null && echo "    started $c"; done
    echo "-- waiting for the API to come back"
    for i in $(seq 1 60); do
      if timeout 5 $K get --raw=/readyz >/dev/null 2>&1; then echo "   back after ${i}0s at most"; break; fi
      sleep 5
    done
    sleep 10
    status
    ;;

  *) echo "usage: $0 <status|kill N|restore>"; exit 1 ;;
esac
