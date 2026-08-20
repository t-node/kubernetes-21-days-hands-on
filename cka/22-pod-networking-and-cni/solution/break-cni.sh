#!/usr/bin/env bash
# RUNS INSIDE A KIND NODE. Take the CNI configuration away, and put it back.
#
#   bash solution/run-in-node.sh break-cni.sh break
#   bash solution/run-in-node.sh break-cni.sh fix
#
# Removing /etc/cni/net.d does NOT touch running pods -- their networking is
# already set up. It stops NEW pods from being created on this node, and the
# kubelet reports the node NotReady. That asymmetry is the lesson.
set -uo pipefail
SRC=/etc/cni/net.d
BAK=/root/cni-net.d.backup

case "${1:-}" in
  break)
    [ -d "$SRC" ] || { echo "$SRC does not exist -- already broken?"; exit 1; }
    rm -rf "$BAK"
    mv "$SRC" "$BAK"
    mkdir -p "$SRC"
    echo "-- moved $SRC to $BAK; the directory is now empty:"
    ls -la "$SRC"
    echo
    echo "Now, from your workstation:"
    echo "   kubectl get nodes            # this node goes NotReady within ~30s"
    echo "   kubectl describe node <n> | grep -A3 NetworkReady"
    echo "   kubectl run cnitest --image=nginx:alpine --overrides='{\"spec\":{\"nodeName\":\"<n>\"}}'"
    echo "   kubectl describe pod cnitest | grep -A5 Events"
    ;;
  fix)
    [ -d "$BAK" ] || { echo "no backup at $BAK"; exit 1; }
    rm -rf "$SRC"
    mv "$BAK" "$SRC"
    echo "-- restored:"
    ls -la "$SRC"
    echo
    echo "The node returns to Ready within about 30 seconds and pending pods start."
    ;;
  *)
    echo "usage: $0 <break|fix>"; exit 1 ;;
esac
