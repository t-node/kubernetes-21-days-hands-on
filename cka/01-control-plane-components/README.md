# CKA 01 — Control Plane Components in Depth

**Time:** 60-75 minutes
**Prerequisites:** [Day 01](../../days/day-01-architecture-and-kind-cluster/)
**Source lectures:** 14, 15, 16, 17

Day 01 named the components and said what each does in a sentence. That is
enough to draw the architecture diagram. It is not enough to *fix* a cluster.

This assignment goes one level down: the timers the node controller actually
uses, the two-phase algorithm the scheduler runs, why the kubelet is the one
component `kubeadm` will not install for you, and what kube-proxy physically
writes into the kernel.

---

## Part 1 - Concepts

### 1.1 kube-controller-manager: one binary, dozens of loops

A **controller** is a process that watches one kind of object and works
continuously to move actual state toward desired state. That is the whole idea
of Kubernetes in one sentence, and controllers are where it is implemented.

Every construct you have used — Deployments, ReplicaSets, Services, Namespaces,
PersistentVolumes, Jobs — is "intelligent" only because a controller watches it.
There is no magic anywhere else.

They ship as a **single binary**, `kube-controller-manager`, running them all in
one process.

**The node controller's timers are worth memorising** — they explain the
five-minute pause you saw on Day 04 and Day 18:

| Setting | Default | What it governs |
|---|---|---|
| `--node-monitor-period` | **5s** | how often node health is checked |
| `--node-monitor-grace-period` | **40s** | silence before a node is marked `NotReady` |
| `--pod-eviction-timeout` | **5m** | how long after that before its pods are evicted |

A dead node takes **40 seconds** to be noticed and about **5 minutes 40 seconds**
before its pods move. Not sluggishness — a deliberate refusal to reschedule the
cluster over a brief network blip.

> Modern Kubernetes implements the eviction half with **taints** rather than one
> timer: the node controller applies
> `node.kubernetes.io/unreachable:NoExecute`, and pods carry a default
> toleration with `tolerationSeconds: 300`. Same five minutes, now tunable per
> pod. `--pod-eviction-timeout` is deprecated in favour of it.

One more flag worth knowing:

```
--controllers=*,bootstrapsigner,tokencleaner
```

All controllers are enabled by default. If one genuinely is not running —
nothing signs your CSRs, nothing creates ServiceAccount tokens — **this flag is
the first place to look.**

### 1.2 kube-scheduler: it decides, it does not place

> **The scheduler never starts a container.** It picks a node and writes that
> name into the Pod object. The **kubelet** on that node notices and does the
> work.

This explains a real debugging split: a pod stuck `Pending` with **no**
scheduling events is a scheduler problem; a pod that *is* scheduled but not
running is a **kubelet** or image problem. The `nodeName` field tells you which
side of the line you are on.

**Phase 1 — Filtering.** Eliminate nodes that *cannot* work: insufficient CPU or
memory against **requests**, a taint with no matching toleration, an unsatisfied
`nodeSelector` or required affinity, a host port already taken, a volume that
cannot attach here.

**Phase 2 — Scoring.** Rank the survivors 0-10. The most intuitive scorer is
`LeastRequestedPriority` — how much would remain free after placing this pod?

```
Pod requests 2 CPU

node-a: 4 CPU total, 2 already requested  ->  0 free after  ->  low score
node-b: 8 CPU total, 0 already requested  ->  6 free after  ->  HIGH score  <- wins
```

Other scorers spread pods of one Service across nodes, prefer nodes that already
cached the image, and honour `preferred` affinity. Scores are weighted and
summed; highest total wins.

**Everything in the Scheduling section — taints, affinity, priority classes,
custom schedulers — influences one of these two phases.** Filtering is hard
constraints; scoring is preferences.

### 1.3 kubelet: the one you must install yourself

The only component that **actually creates containers**. It:

1. **registers the node** with the cluster
2. watches the API server for pods assigned to *its* `nodeName`
3. tells the container runtime over CRI to pull images and start containers
4. runs your **liveness, readiness and startup probes**
5. reports node and pod status back, continuously
6. reads **static pod** manifests from disk (CKA 05)

> ### The fact that matters most
>
> **`kubeadm` does not install or upgrade the kubelet.**
>
> Every other control-plane component is a static pod, so `kubeadm` can swap its
> image. The kubelet is the thing that *runs* static pods, so it cannot be one —
> it is a **systemd service**, installed and upgraded with the OS package
> manager.
>
> That is exactly why the upgrade procedure in
> [CKA 12](../12-cluster-maintenance/) has a separate `apt-get install -y
> kubelet` step on every node, and why `kubectl get nodes` keeps showing the old
> version until you run it.

Modern kubelets take most settings from a **config file**, not flags:
`/var/lib/kubelet/config.yaml`, with `/etc/kubernetes/kubelet.conf` holding its
kubeconfig. Flags still work but are being deprecated.

### 1.4 kube-proxy: a Service is not a thing

The most important idea here.

> **A Service has no process, no container and no network interface. It exists
> only as a record in etcd and as rules in each node's kernel.**

So when a pod sends a packet to `10.96.43.17:8080`, what receives it? Nothing.
There is no listener at that address anywhere in the cluster.

**kube-proxy** makes the fiction work. It runs on every node — as a
**DaemonSet**, one pod per node — watches Services and EndpointSlices, and
programs the kernel:

```
Service backend  ClusterIP 10.96.43.17:8080
Endpoints        10.244.1.12:8080, 10.244.2.8:8080

              |  kube-proxy writes iptables rules
              v
  -A KUBE-SERVICES -d 10.96.43.17/32 --dport 8080 -j KUBE-SVC-XXX
  -A KUBE-SVC-XXX  --probability 0.5 -j KUBE-SEP-AAA     # -> 10.244.1.12
  -A KUBE-SVC-XXX                    -j KUBE-SEP-BBB     # -> 10.244.2.8
```

The packet is **DNAT'd in the kernel** before it leaves the node. Two
consequences you have already met:

- Load balancing is **random per connection** — that is the `--probability`
  line. Which is why Day 06 said a keep-alive client pins to one pod.
- There is **no userspace proxy in the path**, so kube-proxy being briefly down
  does not break existing connections; the rules stay in the kernel.

| Mode | Mechanism | Notes |
|---|---|---|
| `iptables` | linear rule chains | the long-time default |
| `ipvs` | kernel L4 balancer, hash tables | scales far better past ~1000 Services |
| `nftables` | modern iptables successor | GA in recent releases |

### 1.5 Where every component's configuration lives

Day 01 Step 6b taught the three places. Here is the whole set — the lookup you
will use in the exam:

| Component | kubeadm cluster | Built from scratch |
|---|---|---|
| kube-apiserver | `/etc/kubernetes/manifests/kube-apiserver.yaml` | `/etc/systemd/system/kube-apiserver.service` |
| kube-controller-manager | `/etc/kubernetes/manifests/kube-controller-manager.yaml` | `.../kube-controller-manager.service` |
| kube-scheduler | `/etc/kubernetes/manifests/kube-scheduler.yaml` | `.../kube-scheduler.service` |
| etcd | `/etc/kubernetes/manifests/etcd.yaml` | `.../etcd.service` |
| **kubelet** | **`/var/lib/kubelet/config.yaml`** + systemd | same |
| **kube-proxy** | **a ConfigMap** (`kube-proxy` in `kube-system`) | `.../kube-proxy.service` |

**Note the last two rows.** kubelet and kube-proxy are *not* static pods, so
they are not in `/etc/kubernetes/manifests/`. Looking for them there and finding
nothing is a rite of passage.

---

## Part 2 - Hands-on lab

### Step 1: Find every component and its real configuration

```bash
kubectl get pods -n kube-system -o wide
```

Sort them by *how* they run — this is the distinction that matters:

```bash
echo "--- STATIC PODS (owned by the Node, no scheduler involved) ---"
for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  printf "%-26s owner=%s\n" "$c" \
    "$(kubectl get pod ${c}-devops-control-plane -n kube-system \
       -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)"
done

echo "--- DAEMONSETS (one per node, scheduled normally) ---"
kubectl get daemonset -n kube-system

echo "--- NOT A POD AT ALL ---"
docker exec devops-control-plane systemctl is-active kubelet
```

**Three different mechanisms, in one screen.** The control plane is static pods
owned by the `Node`; kube-proxy and the CNI are DaemonSets; the kubelet is a
systemd service that is not a pod because it is what runs pods.

### Step 2: Read the controller manager's timers

```bash
docker exec devops-control-plane sh -c \
  "grep -E '^\s+- --' /etc/kubernetes/manifests/kube-controller-manager.yaml"
```

The timers from 1.1 are usually **absent** — they are defaults, not written out.
Confirm them from the running process and from the API:

```bash
docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ube-controller-manager | xargs -n1 | grep -E 'monitor|eviction|controllers'"

kubectl get --raw /healthz/poststarthook/start-kube-controller-manager 2>/dev/null || echo "(hook not exposed)"
```

Now find the two flags that make [CKA 15](../15-certificates-api-and-authorization/)
work — this is the same file that signs your CSRs:

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'cluster-signing|service-account-private' /etc/kubernetes/manifests/kube-controller-manager.yaml"
```

### Step 3: Prove the scheduler only decides

Create a pod and catch it between the two stages:

```bash
kubectl run decides --image=nginx:alpine -n default
kubectl get pod decides -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl get events --field-selector involvedObject.name=decides
```

```
Normal  Scheduled  default-scheduler  Successfully assigned default/decides to devops-worker
Normal  Pulling    kubelet            Pulling image "nginx:alpine"
Normal  Started    kubelet            Started container decides
```

**One event from `default-scheduler`, the rest from `kubelet`.** The scheduler's
entire contribution is the first line: it wrote `nodeName`. Everything after is
the kubelet.

Now remove the scheduler and watch the split become obvious:

```bash
docker exec devops-control-plane mv \
  /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 20

kubectl run undecided --image=nginx:alpine -n default
sleep 10
kubectl get pod undecided
kubectl get pod undecided -o jsonpath='{.spec.nodeName}{"\n"}'   # EMPTY
kubectl describe pod undecided | grep -A3 Events                 # no events at all
```

`Pending`, empty `nodeName`, **zero events**. Nothing has an opinion about this
pod because the only thing that assigns nodes is gone.

Now bypass the scheduler entirely — proving the kubelet needs nothing from it:

```bash
kubectl delete pod undecided --force --grace-period=0 2>/dev/null
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: self-assigned
spec:
  nodeName: devops-worker
  containers:
    - name: c
      image: nginx:alpine
EOF
sleep 8
kubectl get pod self-assigned -o wide
```

**Running, with no scheduler in the cluster.** You did the scheduler's one job
by hand. That is exactly what CKA 05's manual scheduling covers.

Restore:

```bash
docker exec devops-control-plane mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 25
kubectl get pods -n kube-system | grep scheduler
kubectl delete pod decides self-assigned --ignore-not-found
```

### Step 4: Watch the node controller's timers for real

```bash
kubectl get nodes
docker stop devops-worker2
```

Now time it:

```bash
for i in $(seq 1 20); do
  printf "%3ds  %s\n" $((i*5)) \
    "$(kubectl get node devops-worker2 --no-headers 2>/dev/null | awk '{print $2}')"
  sleep 5
done
```

`Ready` for roughly the first 40 seconds, then `NotReady`. That is
`--node-monitor-grace-period`, measured on your own cluster.

Watch the taint appear — the modern eviction mechanism from 1.1:

```bash
kubectl describe node devops-worker2 | grep -A4 Taints
```

```
node.kubernetes.io/unreachable:NoExecute
node.kubernetes.io/unreachable:NoSchedule
```

And the toleration the scheduler quietly added to every pod:

```bash
kubectl get pod -n devboard -l app=backend \
  -o jsonpath='{.items[0].spec.tolerations}' | tr ',' '\n' | grep -A2 unreachable
```

`tolerationSeconds: 300`. **There is your five minutes**, written on the pod
rather than configured on the controller.

```bash
docker start devops-worker2
```

### Step 5: See the iptables rules kube-proxy wrote

The payoff of 1.4 — the Service you have used for 20 days, as kernel rules:

```bash
SVC_IP=$(kubectl get svc backend -n devboard -o jsonpath='{.spec.clusterIP}')
echo "backend ClusterIP: $SVC_IP"
kubectl get endpoints backend -n devboard
```

Find that IP in the node's NAT table:

```bash
docker exec devops-control-plane sh -c \
  "iptables-save -t nat 2>/dev/null | grep -i '$SVC_IP' | head -5"
```

```
-A KUBE-SERVICES -d 10.96.43.17/32 -p tcp --dport 8080 -j KUBE-SVC-ABCDEF...
```

Follow the chain to the individual endpoints:

```bash
CHAIN=$(docker exec devops-control-plane sh -c \
  "iptables-save -t nat | grep -m1 '$SVC_IP' | grep -o 'KUBE-SVC-[A-Z0-9]*'")
echo "chain: $CHAIN"
docker exec devops-control-plane sh -c "iptables-save -t nat | grep '$CHAIN'"
```

You should see `--probability` and one jump per backing pod. **That is the load
balancer** — no process, no proxy, a probability in a kernel rule.

Confirm what wrote them:

```bash
kubectl get daemonset kube-proxy -n kube-system
kubectl get configmap kube-proxy -n kube-system \
  -o jsonpath='{.data.config\.conf}' | grep -E "mode:|clusterCIDR:"
```

An **empty `mode:`** means iptables, the default.

Now prove the rules are the mechanism:

```bash
kubectl scale deployment backend --replicas=4 -n devboard
kubectl rollout status deployment/backend -n devboard
docker exec devops-control-plane sh -c "iptables-save -t nat | grep -c '$CHAIN'"
kubectl scale deployment backend --replicas=2 -n devboard
```

The rule count tracked the endpoint count. kube-proxy rewrote the kernel because
EndpointSlices changed — no restart, nothing you did.

### Step 6: Read the kubelet's real configuration

```bash
docker exec devops-control-plane cat /var/lib/kubelet/config.yaml | head -30
docker exec devops-control-plane sh -c \
  "grep -E 'staticPodPath|evictionHard|maxPods|cgroupDriver' /var/lib/kubelet/config.yaml"
```

Three settings that connect to work you have already done:

- **`staticPodPath: /etc/kubernetes/manifests`** — why editing a file there
  restarts a control-plane component (CKA 12)
- **`evictionHard`** — the thresholds behind `MemoryPressure` and
  `DiskPressure` (Day 16)
- **`cgroupDriver: systemd`** — a mismatch between this and the runtime's driver
  is a classic "kubelet will not start"

---

## Validate

```bash
kubectl get pod kube-scheduler-devops-control-plane -n kube-system \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'          # Node

kubectl get daemonset kube-proxy -n kube-system --no-headers
kubectl get pods -n kube-system | grep -c kubelet                   # 0
docker exec devops-control-plane systemctl is-active kubelet        # active

SVC_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
docker exec devops-control-plane sh -c "iptables-save -t nat | grep -c $SVC_IP"
```

You are done when you can answer, without looking:

1. What are the node controller's three timers and what does each do?
2. Which component assigns a pod to a node, and which starts the container?
3. Why can the kubelet not be a static pod?
4. What does a Service physically consist of?
5. Where does kube-proxy's config live, and why not in `/etc/kubernetes/manifests/`?
6. A pod is Pending with **no events at all**. What is broken?

---

## Break it

**A. Stop the controller manager and watch self-healing die.**

```bash
docker exec devops-control-plane mv \
  /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
sleep 20

kubectl delete pod -n devboard -l app=frontend --wait=false
sleep 25
kubectl get pods -n devboard -l app=frontend
```

**The pods are gone and no replacements appear.** The Deployment still says it
wants two; nothing is left to notice the gap.

**Self-healing is not a property of Kubernetes — it is a running process.**

```bash
docker exec devops-control-plane mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
sleep 30
kubectl get pods -n devboard -l app=frontend      # they come back
```

**B. Stop kube-proxy — existing connections survive, new endpoints do not.**

```bash
kubectl -n kube-system patch daemonset kube-proxy \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"nonexistent":"true"}}}}}'
sleep 25
kubectl get pods -n kube-system -l k8s-app=kube-proxy      # none

curl -s -o /dev/null -w "still works: %{http_code}\n" http://localhost:30080
```

**Still 200.** The rules kube-proxy wrote are still in the kernel — it is not in
the data path. But nothing maintains them now:

```bash
kubectl scale deployment frontend --replicas=4 -n devboard
kubectl rollout status deployment/frontend -n devboard
kubectl get endpoints devboard-frontend -n devboard        # 4 endpoints
docker exec devops-control-plane sh -c "iptables-save -t nat | grep -c KUBE-SEP"
```

Four endpoints exist, but **no new rules were written**, so two of those pods
receive nothing. Restore:

```bash
kubectl -n kube-system patch daemonset kube-proxy --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/nonexistent"}]'
sleep 30
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl scale deployment frontend --replicas=2 -n devboard
```

**C. The cgroup driver mismatch (read, do not run).**

Setting `cgroupDriver: cgroupfs` in `/var/lib/kubelet/config.yaml` while
containerd uses `systemd` makes the kubelet refuse to start:

```
failed to create kubelet: misconfiguration: kubelet cgroup driver: "cgroupfs"
is different from runtime cgroup driver: "systemd"
```

The node goes `NotReady` and its pods are eventually evicted. One of the most
common real kubelet failures — and `journalctl -u kubelet` is where the answer
always is.

---

## Exam-style tasks

1. Report which flags the controller manager uses for CSR signing, two ways.
   *(2 min)*
2. A pod is `Pending` with no events. Determine in under a minute whether the
   scheduler is running. *(2 min)*
3. Schedule a pod onto `devops-worker2` **without** the scheduler. *(3 min)*
4. Find the ClusterIP of `kube-dns` and prove kube-proxy has programmed rules
   for it. *(4 min)*
5. Report the kubelet's static pod path and its hard eviction thresholds.
   *(3 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# what runs how
kubectl get pods -n kube-system -o wide
kubectl get pod <static-pod> -n kube-system \
  -o jsonpath='{.metadata.ownerReferences[0].kind}'          # Node
kubectl get daemonset -n kube-system
docker exec <node> systemctl status kubelet

# effective flags -- works even when the manifest is not where you expect
docker exec <node> sh -c "ps aux | grep [k]ube-controller-manager | xargs -n1 | grep '^--'"

# kubelet
docker exec <node> cat /var/lib/kubelet/config.yaml
docker exec <node> journalctl -u kubelet -n 50 --no-pager

# kube-proxy
kubectl get configmap kube-proxy -n kube-system -o yaml
docker exec <node> sh -c "iptables-save -t nat | grep <clusterIP>"
```

| Component | Runs as | Config lives in |
|---|---|---|
| apiserver, scheduler, controller-manager, etcd | **static pod** | `/etc/kubernetes/manifests/*.yaml` |
| kube-proxy, CNI | **DaemonSet** | a **ConfigMap** in `kube-system` |
| **kubelet** | **systemd service** | `/var/lib/kubelet/config.yaml` |

| Timer | Default |
|---|---|
| node monitor period | 5s |
| node monitor grace period | **40s** → `NotReady` |
| pod eviction / `tolerationSeconds` | **300s** → pods move |

**Scheduler decides. Kubelet places. kube-proxy makes Services real.**

---

**Next: [CKA 02 — Container runtimes](../02-container-runtimes-and-crictl/)**
