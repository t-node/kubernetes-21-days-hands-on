# Day 16 — Requests, Limits, QoS & metrics-server

**Time:** 60-75 minutes
**Prerequisites:** Days 12-15

Requests and limits look like two similar numbers. They do completely different
jobs, one of them decides whether your pod gets scheduled at all, and the other
decides whether it gets killed. Today you also install metrics-server, which
Day 17's autoscaler cannot work without.

---

## Part 1 - Concepts

### 16.1 Requests vs limits — the one thing to get right

```yaml
resources:
  requests:            # what the SCHEDULER reserves for you
    cpu: 100m
    memory: 128Mi
  limits:              # what the KERNEL enforces at runtime
    cpu: 500m
    memory: 512Mi
```

| | **requests** | **limits** |
|---|---|---|
| Used by | the **scheduler**, to pick a node | the **kubelet/kernel**, at runtime |
| Meaning | "reserve at least this much" | "never let me exceed this" |
| If omitted | scheduler assumes 0 — pod lands anywhere | unbounded — the pod can starve the node |
| Enforced by | node capacity accounting | cgroups |

**The scheduler only ever looks at requests.** A node is "full" when the *sum of
requests* of its pods equals its allocatable capacity — regardless of actual
usage. A node can be 10% utilised and still refuse pods, because everything on
it requested more than it uses.

### 16.2 CPU and memory behave completely differently under pressure

This is the single most important distinction of the day.

**CPU is compressible.** Exceed your CPU limit and you are **throttled** —
slowed down, never killed. The kernel's CFS quota simply stops scheduling you
until the next period.

**Memory is incompressible.** Exceed your memory limit and you are
**OOMKilled** — terminated immediately, no grace period, exit code 137.

```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# OOMKilled
```

Consequences for how you set them:

- **Memory limit too low = crashes.** Set it above your real peak, with headroom.
- **CPU limit too low = latency**, and it can be surprisingly severe. A process
  that briefly needs 2 cores but is limited to 500m gets throttled hard, and p99
  latency collapses while average CPU looks low.

Units:

| Resource | Unit | Notes |
|---|---|---|
| CPU | `1` = 1 core, `500m` = 0.5 core | `m` = millicores; `100m` = 10% of a core |
| Memory | `Mi`/`Gi` (binary) or `M`/`G` (decimal) | `1Gi` = 1073741824, `1G` = 1000000000. **Use `Mi`/`Gi`** |

### 16.3 CPU limits are genuinely controversial

Many experienced teams **set CPU requests but no CPU limit**:

- The request already guarantees a fair share under contention.
- A limit throttles you even when the node is idle — you waste capacity you
  could have used for free.
- CFS throttling has historically caused severe tail-latency problems even for
  workloads well under their limit.

The counter-argument: without limits, one noisy neighbour can consume all spare
CPU, and your performance becomes unpredictable between deploys.

**A defensible answer in an interview:** always set memory requests *and* limits
(usually equal, for predictability); always set CPU requests; be deliberate
about CPU limits, and in latency-sensitive services consider omitting them.

### 16.4 QoS classes — who gets killed first

Kubernetes assigns each pod a class, derived purely from its resources:

| Class | Condition | Evicted |
|---|---|---|
| **Guaranteed** | every container has requests **==** limits, for both CPU and memory | last |
| **Burstable** | at least one request set, but not equal to limits | second |
| **BestEffort** | no requests or limits at all | **first** |

```bash
kubectl get pod <pod> -o jsonpath='{.status.qosClass}{"\n"}'
```

Under node memory pressure the kubelet evicts BestEffort pods first, then
Burstable pods that exceed their requests, and Guaranteed pods last. Anything
critical — your database — should be Guaranteed.

> Note that QoS governs **eviction under node pressure**. A container that
> exceeds its own memory *limit* is OOMKilled immediately regardless of class.

### 16.5 Allocatable is not capacity

```bash
kubectl describe node devops-worker | grep -A6 "Allocatable"
```

A node reserves resources for the kubelet, the container runtime, the OS and an
eviction threshold. **Allocatable = capacity − reserved**, and only allocatable
is schedulable. On small nodes the difference is substantial — a 2 GB node might
offer 1.5 GB.

### 16.6 metrics-server

`kubectl top` and the HPA both need actual usage data, which the core API does
not provide. **metrics-server** scrapes each kubelet's summary API and serves
the `metrics.k8s.io` API.

Without it:

```bash
kubectl top nodes
# error: Metrics API not available
```

Two things to know:

- It holds only **recent, in-memory** data — roughly the last minute. It is not
  monitoring. For history, alerting and dashboards you need Prometheus.
- On kind (and many self-managed clusters) it needs `--kubelet-insecure-tls`,
  because kubelet serving certificates are self-signed and not in the cluster
  CA. In production you fix the certificates instead of disabling verification.

### 16.7 How to choose the numbers

Guessing is normal at the start; measuring is the job.

1. Deploy with a generous limit and no strong opinion.
2. Run realistic load.
3. Observe with `kubectl top` (rough) or Prometheus (proper) over days.
4. Set **requests ≈ p50-p90 usage**, so the scheduler packs efficiently.
5. Set **memory limit ≈ peak + 50% headroom**; consider requests == limits for
   critical workloads.
6. Revisit after any significant change.

The Vertical Pod Autoscaler can do steps 3-5 for you in recommendation mode,
which is a genuinely useful way to find sane starting values.

---

## Part 2 - Hands-on lab

### Step 1: Prove metrics are missing

```bash
kubectl top nodes
# error: Metrics API not available
kubectl get apiservices | grep metrics
```

### Step 2: Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl logs -n kube-system -l k8s-app=metrics-server --tail=20
```

It will **not** become Ready on kind. The logs say why:

```
x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs
```

kind's kubelets serve self-signed certificates. Patch it:

```bash
kubectl patch deployment metrics-server -n kube-system --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl rollout status deployment/metrics-server -n kube-system
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

> `--kubelet-insecure-tls` disables verification of the kubelet's certificate.
> Correct for a local learning cluster; **never** in production, where you fix
> the certificates instead (`--rotate-server-certificates` on the kubelet plus a
> CSR approver).

A committed copy of the patch is in `solution/patches/metrics-server-patch.yaml`.
It lives in a subdirectory on purpose: it is a *patch*, not a manifest, and
`kubectl apply -f solution/` would reject it. (`apply -f <dir>` is not
recursive, so the subdirectory is skipped.)

### Step 3: Read actual usage

Wait roughly 60 seconds for the first scrape, then:

```bash
kubectl top nodes
kubectl top pods -n devboard
kubectl top pods -n devboard --containers
kubectl top pods -A --sort-by=memory | head -15
kubectl top pods -A --sort-by=cpu | head -15
```

```
NAME                   CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
devops-control-plane   142m         7%     1180Mi          30%
devops-worker          38m          1%     420Mi           10%
```

Compare what your pods actually use with what you requested:

```bash
kubectl top pods -n devboard
kubectl get pods -n devboard -o custom-columns=\
NAME:.metadata.name,\
CPU_REQ:.spec.containers[0].resources.requests.cpu,\
MEM_REQ:.spec.containers[0].resources.requests.memory,\
MEM_LIM:.spec.containers[0].resources.limits.memory
```

The Go backend idles at a few MiB — Go binaries are frugal. The frontend runs a
Node process and uses considerably more. Right there is the argument from Day 08
for serving `dist/` from nginx instead.

### Step 4: See the QoS classes

```bash
kubectl get pods -n devboard -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass
```

Everything is `Burstable` — requests are set but differ from limits. Now create
one of each:

```bash
kubectl apply -f solution/01-qos-demo.yaml
kubectl get pods -n devboard -l demo=qos -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass
```

```
NAME             QOS
qos-besteffort   BestEffort
qos-burstable    Burstable
qos-guaranteed   Guaranteed
```

Look at `qos-guaranteed` and note the subtlety: it sets **only limits**, and
Kubernetes copies them to requests automatically, making them equal.

```bash
kubectl get pod qos-guaranteed -n devboard \
  -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl delete -f solution/01-qos-demo.yaml
```

### Step 5: Watch an OOMKill

```bash
kubectl apply -f solution/02-oom-demo.yaml
kubectl get pod oom-demo -n devboard -w        # Ctrl-C after two restarts
```

```
oom-demo   0/1   OOMKilled          0
oom-demo   0/1   CrashLoopBackOff   1
```

```bash
kubectl describe pod oom-demo -n devboard | grep -A6 "Last State"
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

**Memorise exit code 137** = 128 + 9 = SIGKILL. It nearly always means OOM. The
container asked for 100 MB with a 50Mi limit; the kernel killed it instantly, no
grace period, no chance to log anything.

```bash
kubectl delete -f solution/02-oom-demo.yaml
```

### Step 6: Watch CPU throttling — no kill, just slow

```bash
kubectl apply -f solution/03-cpu-throttle-demo.yaml
kubectl wait --for=condition=Ready pod/cpu-throttle -n devboard --timeout=60s
sleep 60

kubectl top pod cpu-throttle -n devboard
```

The pod tries to burn a full core but is limited to `200m`, so `kubectl top`
reports about 200m — pinned exactly at the limit. It is **not** restarted:

```bash
kubectl get pod cpu-throttle -n devboard      # Running, RESTARTS 0
```

See the throttling directly in the cgroup:

```bash
kubectl exec -n devboard cpu-throttle -- \
  sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.stat'
```

```
nr_periods 583
nr_throttled 578        <- throttled in nearly every period
throttled_usec 51203847
```

`nr_throttled / nr_periods` is the metric to alert on in production. A high
ratio means real latency damage even though CPU usage looks modest and nothing
has crashed.

```bash
kubectl delete -f solution/03-cpu-throttle-demo.yaml
```

### Step 7: Watch the scheduler refuse on requests alone

```bash
kubectl describe node devops-worker | grep -A8 "Allocated resources"
```

Now ask for something no node can satisfy:

```bash
kubectl apply -f solution/04-unschedulable.yaml
kubectl get pod greedy -n devboard              # Pending, forever
kubectl describe pod greedy -n devboard | tail -6
```

```
Warning  FailedScheduling  0/3 nodes are available:
         3 Insufficient memory.
```

**Nothing is actually using that memory.** The scheduler refused purely on the
sum of *requests*. This is the most common cause of `Pending` in real clusters
and the reason inflated requests are expensive: you pay for nodes that sit idle.

```bash
kubectl delete -f solution/04-unschedulable.yaml
```

### Step 8: Set sensible values for DevBoard

Use what you measured in Step 3:

```bash
kubectl apply -f solution/05-backend-with-resources.yaml
kubectl rollout status deployment/backend -n devboard

kubectl get pods -n devboard -l app=backend -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass
kubectl top pods -n devboard -l app=backend
```

The reasoning behind those numbers is in the file's comments — it is the part
worth reading, more than the numbers themselves.

---

## Validate

```bash
kubectl top nodes                       # works
kubectl top pods -n devboard            # works

kubectl get pods -n devboard -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass,\
CPU_REQ:.spec.containers[0].resources.requests.cpu,\
MEM_LIM:.spec.containers[0].resources.limits.memory

kubectl get apiservice v1beta1.metrics.k8s.io \
  -o jsonpath='{.status.conditions[0].status}{"\n"}'      # True
```

**metrics-server must be working before Day 17** — the HPA has no input without
it.

Ready for Day 17 when you can:

1. Say which of requests/limits the scheduler uses, and which the kernel enforces.
2. Explain what happens when you exceed a CPU limit vs a memory limit.
3. Name the three QoS classes and how each is determined.
4. Explain what exit code 137 means.

---

## Break it

**A. No resources at all.**

```bash
kubectl apply -f solution/06-no-resources.yaml
kubectl get pod no-resources -n devboard -o jsonpath='{.status.qosClass}{"\n"}'
# BestEffort
```

This pod is scheduled onto any node regardless of load (it requests nothing), it
can consume unbounded CPU and memory, and it is the **first** thing evicted
under node pressure. It is simultaneously the most dangerous neighbour and the
most fragile tenant.

```bash
kubectl delete -f solution/06-no-resources.yaml
```

**B. Memory limit below the runtime's floor.**

```bash
kubectl apply -f solution/07-limit-too-low.yaml
kubectl get pod tiny-limit -n devboard -w         # Ctrl-C after CrashLoopBackOff
kubectl describe pod tiny-limit -n devboard | grep -A4 "Last State"
```

Postgres cannot start in 16Mi. It is OOMKilled during initialisation, so you
never even see a useful log line. When a container dies before producing logs,
**check the memory limit first** — the message you want is in `describe`, not in
`logs`.

```bash
kubectl delete -f solution/07-limit-too-low.yaml
```

**C. Request more than any single node has.**

```bash
kubectl run huge --image=nginx:alpine -n devboard \
  --overrides='{"spec":{"containers":[{"name":"huge","image":"nginx:alpine","resources":{"requests":{"cpu":"64"}}}]}}'

kubectl get pod huge -n devboard                 # Pending
kubectl describe pod huge -n devboard | grep -A3 Events
# 0/3 nodes are available: 3 Insufficient cpu
kubectl delete pod huge -n devboard
```

Requests cannot be split across nodes. A pod must fit entirely on one.

**D. Kill the whole node with an unlimited pod.**

```bash
kubectl apply -f solution/08-memory-hog.yaml
kubectl get pods -n devboard -w        # Ctrl-C after ~90 seconds
kubectl get events -n devboard --field-selector reason=Evicted
kubectl describe node devops-worker | grep -i -A3 pressure
```

A pod with **no memory limit** allocates until the node hits
`MemoryPressure`. The kubelet then starts evicting — and it evicts **BestEffort
and Burstable pods first**, which can include your application while the hog
survives. One missing limit, collateral damage across the node.

```bash
kubectl delete -f solution/08-memory-hog.yaml
```

**E. Watch a LimitRange supply defaults.**

```bash
kubectl apply -f ../day-03-namespaces/solution/limit-range.yaml
kubectl run defaulted --image=nginx:alpine -n devboard
kubectl get pod defaulted -n devboard -o jsonpath='{.spec.containers[0].resources}{"\n"}'
```

The pod declared nothing, yet has requests and limits — injected by the
LimitRange at admission. This is how a platform team enforces a floor without
requiring every developer to remember.

```bash
kubectl delete pod defaulted -n devboard
kubectl delete -f ../day-03-namespaces/solution/limit-range.yaml
```

---

## Interview questions

<details>
<summary><b>1. Requests vs limits?</b></summary>

Requests are what the scheduler reserves when choosing a node - a node is full
when the sum of requests reaches allocatable, regardless of actual usage. Limits
are enforced at runtime by the kernel through cgroups. Exceeding a CPU limit
throttles the container; exceeding a memory limit gets it OOMKilled. Omitting
requests means the scheduler assumes zero and places the pod anywhere; omitting
limits means it can consume the whole node.
</details>

<details>
<summary><b>2. What happens when a container exceeds its CPU limit? Its memory limit?</b></summary>

CPU is compressible: the container is throttled by the CFS quota - slowed, never
killed - so you see latency, not crashes. Memory is incompressible: the kernel
OOM-kills the container immediately with exit code 137, no grace period and
usually no useful log line. That asymmetry is why memory limits must be
generous and why CPU limits are debated.
</details>

<details>
<summary><b>3. What are the QoS classes?</b></summary>

Guaranteed, when every container sets requests equal to limits for both CPU and
memory. Burstable, when at least one request is set but they do not equal
limits. BestEffort, when nothing is set. Under node memory pressure the kubelet
evicts BestEffort first, then Burstable pods exceeding their requests, then
Guaranteed. Critical workloads such as databases should be Guaranteed.
</details>

<details>
<summary><b>4. Should you set CPU limits?</b></summary>

It is genuinely contested. Requests already guarantee a fair share under
contention, and a limit throttles you even when the node is idle, wasting
capacity and harming tail latency - CFS throttling has caused real p99 problems
even for workloads averaging well under their limit. The counter-argument is
predictability and protection from noisy neighbours. A defensible position:
always set memory requests and limits, always set CPU requests, and be
deliberate about CPU limits - often omitting them for latency-sensitive
services.
</details>

<details>
<summary><b>5. A pod is Pending with "Insufficient memory" but the nodes look idle. Why?</b></summary>

The scheduler only counts requests, never live usage. If existing pods requested
far more than they consume, the node is logically full while physically idle.
The fix is right-sizing requests based on measured usage, not adding hardware.
This is exactly why inflated requests are expensive.
</details>

<details>
<summary><b>6. What is metrics-server and what are its limits?</b></summary>

It scrapes each kubelet's summary API and serves the metrics.k8s.io API, which
is what `kubectl top` and the HPA consume. It keeps only about a minute of
in-memory data, so it is not monitoring - no history, no alerting, no queries.
For those you need Prometheus, and for HPAs on custom or external metrics you
need an adapter as well.
</details>

<details>
<summary><b>7. How do you decide requests and limits for a new service?</b></summary>

Start generous, run realistic load, and measure over days with Prometheus.
Then set requests near p50-p90 usage so the scheduler packs efficiently, and
memory limits at peak plus meaningful headroom. For critical services set
requests equal to limits to get Guaranteed QoS. The VPA in recommendation mode
is a good way to find starting values. Re-measure after significant changes.
</details>

<details>
<summary><b>8. What is exit code 137?</b></summary>

128 + 9, meaning the process received SIGKILL. In Kubernetes it almost always
means OOMKilled - the container exceeded its memory limit - which
`kubectl describe pod` confirms under Last State. It can also mean the container
failed to stop within the termination grace period and was force-killed.
</details>

<details>
<summary><b>9. How would you stop one team consuming a whole cluster?</b></summary>

ResourceQuota per namespace to cap aggregate requests, limits and object counts;
LimitRange to supply defaults and min/max per container so pods without explicit
resources are still bounded; and a PriorityClass scheme so critical workloads
preempt batch work. Beyond that, separate node pools with taints, or separate
clusters for genuinely hostile tenancy.
</details>

---

## Cheat card

```bash
# install metrics-server (kind needs the patch)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl top nodes
kubectl top pods -n devboard --containers
kubectl top pods -A --sort-by=memory | head

# what did I ask for, and what class am I?
kubectl get pods -n devboard -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass,\
CPU_REQ:.spec.containers[0].resources.requests.cpu,\
MEM_LIM:.spec.containers[0].resources.limits.memory

kubectl describe node devops-worker | grep -A8 "Allocated resources"

# was it OOMKilled?
kubectl get pod <pod> -n devboard \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'

# is it being throttled?
kubectl exec -n devboard <pod> -- cat /sys/fs/cgroup/cpu.stat
```

| Symptom | Cause |
|---|---|
| `Pending`, `Insufficient cpu/memory` | requests exceed allocatable on every node |
| `OOMKilled`, exit 137 | memory limit too low |
| Slow, high `nr_throttled`, no restarts | CPU limit too low |
| Evicted under pressure | BestEffort or Burstable over its request |

---

**Next: [Day 17 - Horizontal Pod Autoscaler](../day-17-horizontal-pod-autoscaler/)**
