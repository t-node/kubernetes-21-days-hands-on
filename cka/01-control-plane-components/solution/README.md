# CKA 01 solution

## Exam-style task answers

### 1. CSR signing flags, two ways (2 min)

```bash
docker exec devops-control-plane sh -c \
  "grep cluster-signing /etc/kubernetes/manifests/kube-controller-manager.yaml"

docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ube-controller-manager | xargs -n1 | grep cluster-signing"
```

`--cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt` and
`--cluster-signing-key-file=/etc/kubernetes/pki/ca.key`.

Know both routes: the manifest is the **declared** configuration, `ps` is what
is **actually running**. They differ when an edit has not taken effect, which is
precisely when you need to know.

### 2. Is the scheduler running? (2 min)

```bash
kubectl get pods -n kube-system | grep scheduler
```

If nothing, confirm from the node — `kubectl` may be unreliable if the control
plane is unhealthy:

```bash
docker exec devops-control-plane crictl ps -a --name kube-scheduler
docker exec devops-control-plane ls /etc/kubernetes/manifests/
```

**The giveaway is in the pod itself:** a Pending pod with **no events at all**
means nothing has looked at it. If the scheduler were running and simply could
not place it, there would be a `FailedScheduling` event explaining why. No
events = no scheduler.

```bash
kubectl get pod <name> -o jsonpath='{.spec.nodeName}'   # empty
kubectl describe pod <name> | grep -A3 Events           # none
```

### 3. Schedule without the scheduler (3 min)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: manual
spec:
  nodeName: devops-worker2
  containers:
    - name: c
      image: nginx:alpine
EOF

kubectl get pod manual -o wide
```

Setting `spec.nodeName` **is** the scheduler's entire job. The kubelet on that
node watches for pods bearing its own name and picks this up directly.

Caveats worth stating: `nodeName` bypasses every check — taints, resources,
affinity. If the node is full, the kubelet rejects it and the pod sits
`OutOfcpu` forever with nothing to reschedule it. See CKA 05.

### 4. Prove kube-proxy programmed rules for kube-dns (4 min)

```bash
SVC=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
echo "$SVC"
docker exec devops-control-plane sh -c "iptables-save -t nat | grep $SVC"
```

Expect a `KUBE-SERVICES` rule for ports 53 (UDP and TCP) and 9153, each jumping
to a `KUBE-SVC-*` chain. Follow one to the endpoints:

```bash
CH=$(docker exec devops-control-plane sh -c \
  "iptables-save -t nat | grep -m1 $SVC | grep -o 'KUBE-SVC-[A-Z0-9]*'")
docker exec devops-control-plane sh -c "iptables-save -t nat | grep $CH"
kubectl get endpoints kube-dns -n kube-system
```

The `KUBE-SEP-*` targets correspond one-to-one with the CoreDNS pod IPs.

### 5. Kubelet static pod path and eviction thresholds (3 min)

```bash
docker exec devops-control-plane sh -c \
  "grep -E -A6 'staticPodPath|evictionHard' /var/lib/kubelet/config.yaml"
```

```yaml
staticPodPath: /etc/kubernetes/manifests
evictionHard:
  imagefs.available: 0%
  nodefs.available: 0%
  nodefs.inodesFree: 0%
```

kind sets those to 0% deliberately so a full laptop disk does not evict your
lab. A real node uses the defaults — roughly `nodefs.available: 10%`,
`imagefs.available: 15%`, `memory.available: 100Mi` — which are what produce
`DiskPressure` and `MemoryPressure` and the evictions in Day 16.

---

## The six answers

1. **`--node-monitor-period` 5s** (how often health is checked),
   **`--node-monitor-grace-period` 40s** (silence before `NotReady`),
   **`--pod-eviction-timeout` 5m** (before pods are evicted). Modern clusters
   implement the last one as a `tolerationSeconds: 300` toleration of the
   `unreachable:NoExecute` taint.

2. The **scheduler** assigns — it writes `spec.nodeName` and nothing else. The
   **kubelet** on that node starts the container via the CRI runtime.

3. Because the kubelet is **what runs static pods**. A static pod is started by
   the kubelet reading a file; if the kubelet were itself a static pod, nothing
   would exist to start it. So it is a systemd service, which is also why
   `kubeadm` cannot upgrade it.

4. **A record in etcd plus iptables/IPVS rules on every node.** No process, no
   container, no interface. kube-proxy writes the rules; the kernel does the
   DNAT.

5. In a **ConfigMap** named `kube-proxy` in `kube-system`, because kube-proxy is
   a **DaemonSet**, not a static pod. Only the four static pods live in
   `/etc/kubernetes/manifests/`.

6. **The scheduler is not running.** A scheduler that is running but cannot
   place the pod always emits a `FailedScheduling` event naming the reason.
   Complete silence means nothing has evaluated the pod at all.

---

## Carry this forward

**The debugging split this assignment gives you:**

```bash
kubectl get pod X -o jsonpath='{.spec.nodeName}'
```

- **Empty** → the scheduler has not acted. Is it running? Does any node pass
  filtering?
- **Set, but not running** → the scheduler did its job. The problem is the
  **kubelet** or the image: `crictl ps -a` and `journalctl -u kubelet` on that
  node.

One field, and it halves your search space.
