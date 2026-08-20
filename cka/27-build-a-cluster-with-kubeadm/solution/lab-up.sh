#!/usr/bin/env bash
# Create two "machines" for the kubeadm lab.
#
#   bash solution/lab-up.sh
#
# They are Docker containers from the kindest/node image, run privileged with
# systemd as PID 1 -- which is exactly how kind builds its own nodes. The image
# already contains containerd, kubeadm, kubelet, kubectl and the control-plane
# images for this version, so nothing is downloaded and nothing is installed.
#
# What this gives you that `kind create cluster` does not: you run kubeadm
# yourself, on machines that have no cluster on them.
set -euo pipefail
IMAGE=${IMAGE:-kindest/node:v1.31.4}
NET=${NET:-kubeadm-lab}
CP=${CP:-kubeadm-cp}
WK=${WK:-kubeadm-wk}

command -v docker >/dev/null || { echo "docker is required"; exit 1; }

echo "==> network"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
echo "    $NET"

start_node() {   # start_node <name>
  local n=$1
  if docker inspect "$n" >/dev/null 2>&1; then
    echo "    $n already exists -- remove it with lab-down.sh to start clean"
    return 0
  fi
  echo "==> starting $n"
  docker run -d \
    --name "$n" --hostname "$n" \
    --privileged \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    --tmpfs /tmp --tmpfs /run \
    --volume /lib/modules:/lib/modules:ro \
    --volume "/var" \
    --network "$NET" \
    --cgroupns=private \
    --restart=on-failure:1 \
    "$IMAGE" >/dev/null
}

start_node "$CP"
start_node "$WK"

echo "==> waiting for systemd inside each node"
for n in "$CP" "$WK"; do
  for i in $(seq 1 60); do
    if docker exec "$n" systemctl is-system-running >/dev/null 2>&1 \
       || docker exec "$n" systemctl is-system-running 2>/dev/null | grep -q degraded; then
      echo "    $n up"; break
    fi
    sleep 2
    [ "$i" = "60" ] && { echo "    $n did not start systemd in 120s"; docker logs --tail 20 "$n"; exit 1; }
  done
done

echo "==> preparing both nodes (27.2)"
for n in "$CP" "$WK"; do
  docker exec "$n" sh -c '
    swapoff -a 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    printf "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n" \
      > /etc/sysctl.d/k8s.conf
    sysctl --system >/dev/null 2>&1 || true
    systemctl enable --now containerd >/dev/null 2>&1 || true
  '
  echo "    $n prepared"
done

echo
echo "==> the two machines, with no cluster on them:"
docker ps --filter "name=kubeadm-" --format "    {{.Names}}\t{{.Status}}"
echo
for n in "$CP" "$WK"; do
  ip=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$NET\").IPAddress }}" "$n")
  printf "    %-12s %s\n" "$n" "$ip"
done
echo
echo "Verify they really are empty:"
echo "   docker exec $CP crictl ps          # nothing"
echo "   docker exec $CP ls /etc/kubernetes # nothing"
echo
echo "Next:  bash solution/kubeadm-init.sh"
