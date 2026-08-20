# CKA 06 solution

## Challenge answers

### C1 - Rank a real cluster

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: payments-critical}
value: 100000
description: "Payments. May preempt. Never evicted by app workloads."
# preemptionPolicy omitted -> PreemptLowerPriority (the default). Intentional.
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: reporting}
value: 10000
preemptionPolicy: Never          # <- the whole point of this class
description: "Ahead of batch in the queue, but disrupts nothing."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: batch}
value: 100
description: "Nightly ETL. First victim when the cluster is full."
```

```yaml
# payments Deployment
spec:
  template:
    spec:
      priorityClassName: payments-critical
```
...and `reporting` / `batch` respectively.

**Why `reporting` is above 0:** priority governs **queue order**, not just
preemption. At 0 it would be tied with every unlabelled pod in the cluster and
its position would be arbitrary. At 10000 with `preemptionPolicy: Never` it gets
exactly what was asked for -- first in line for freed capacity, harmless to
anything already running.

The common wrong answer is giving `reporting` a low value because "it must not
evict". Eviction is controlled by `preemptionPolicy`, not by the number. Those
are two independent knobs.

### C2 - Preemption forensics

The pod object is gone, so you are reading events and the controller's record.

```bash
# 1. Did something preempt it? Preempted events are recorded against the VICTIM.
kubectl get events -n <ns> --field-selector reason=Preempted
kubectl get events -A --field-selector reason=Preempted --sort-by=.lastTimestamp

# 2. Node-pressure eviction is a DIFFERENT reason, and comes from the kubelet.
kubectl get events -n <ns> --field-selector reason=Evicted

# 3. OOMKill is not an eviction at all -- the pod object survives, the container
#    restarted. So if the pod still exists, it was never preempted:
kubectl get pod <name> -n <ns> \
  -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
kubectl describe pod <name> -n <ns> | grep -E "Last State|Reason|Exit Code"

# 4. Who replaced it -- the ReplicaSet's own events:
kubectl describe rs -n <ns> -l app=<app> | grep -A10 Events
```

The distinguishing signals:

| Cause | Pod object | Where the evidence is | Reason string |
|---|---|---|---|
| **Preempted** | deleted | events in the victim's namespace, source `default-scheduler` | `Preempted` |
| **Node-pressure evicted** | kept, phase `Failed` | events, source `kubelet` | `Evicted` |
| **OOMKilled** | kept, container restarted | `lastState.terminated.reason` | `OOMKilled` |

The preemptor is named in the message: `Preempted by <ns>/<pod> on node <node>`.

**Caveat worth stating in an interview:** events default to a **1 hour** TTL. If
nobody looked within the hour, the evidence is gone and you fall back to audit
logs or the monitoring stack. This is the practical argument for shipping events
somewhere durable.

### C3 - Choose the architecture

Scheduler **profiles**, because two independent scheduler binaries each maintain
their own cache of node allocatable and each makes binding decisions without
seeing the other's in-flight assignments -- so both can place a pod on the same
node in the same instant and **overcommit it**, producing pods that schedule
successfully and then fail to start. A single binary hosting two profiles shares
one informer cache and one internal accounting of assumed pods, so the GPU-aware
profile and the default profile cannot race. It is also one process to deploy,
version-match to the cluster, monitor and upgrade rather than two. GPU topology
logic is a *scoring* concern -- exactly what `pluginConfig` and a custom score
plugin at the `score` extension point exist for.

**When the answer flips:** when you need code the built-in plugins cannot
express *and* cannot be compiled into the scheduler binary -- a third-party
scheduler such as Volcano or YuniKorn shipped as its own image, or a scheduler
maintained on a different release cadence than your control plane. There you
accept the race risk and mitigate it by partitioning nodes (taints + node
selectors) so the two schedulers never consider the same node.

### C4 - Break and diagnose

```bash
# Pending, NO events -- no scheduler is watching
kubectl run silent --image=nginx:alpine --overrides='{"spec":{"schedulerName":"ghost"}}'

# Pending, WITH a FailedScheduling event -- a scheduler looked and refused
kubectl run refused --image=nginx:alpine --overrides='{"spec":{"containers":[{"name":"refused","image":"nginx:alpine","resources":{"requests":{"cpu":"500"}}}]}}'

kubectl describe pod silent  | grep -A3 Events    # <none>
kubectl describe pod refused | grep -A3 Events    # FailedScheduling: Insufficient cpu
```

**What distinguishes them:** the presence of a `FailedScheduling` event proves a
scheduler dequeued the pod, ran the filter phase and found no node. Its absence
proves the pod was never dequeued at all.

- **No events = a cluster problem.** Either the scheduler is down (CKA 05) or
  the pod names one that does not exist. Nothing about the pod's own resources
  will fix it.
- **`FailedScheduling` = a pod problem** (usually). The scheduler is healthy and
  is telling you exactly why -- insufficient CPU, unmatched selector, untolerated
  taint. Read the message; it enumerates the reason per node.

### C5 - Read the profile

`NodeResourcesFit` is disabled at the `filter` extension point, so the scheduler
**never checks whether the pod's requests fit**. A pod requesting 32 CPU on a
4-CPU cluster will be **scheduled successfully** -- bound to a node.

Then it breaks: the **kubelet** performs its own admission check when the pod
arrives, finds the node cannot satisfy 32 CPU, and rejects it. The pod goes to
phase `Failed` with reason `OutOfcpu`.

```
NAME   READY   STATUS      RESTARTS   AGE
big    0/1     OutOfcpu    0          3s
```

Two lessons:

1. **The kubelet is the last line of defence, not the scheduler.** Both check;
   only the kubelet's check is authoritative, because it owns the node.
2. This is a *worse* failure than Pending. A Pending pod is visibly waiting and
   will schedule when capacity appears; an `OutOfcpu` pod is dead and, if it was
   created by a Deployment, will be recreated into the same failure repeatedly.

`NodeResourcesFit` also sits at `score`. Disabling it at `filter` leaves the
score half running, so the scheduler still *ranks* nodes by free resources while
refusing to *require* them -- it will pick the emptiest node and still
overcommit it.

---

## Files

| File | Purpose |
|---|---|
| `01-priority-classes.yaml` | low / high / patient (Never) classes |
| `02-low-priority-filler.yaml` | 6 pause pods that fill a node |
| `03-high-priority-pod.yaml` | triggers preemption |
| `04-high-priority-nopreempt.yaml` | same size, `preemptionPolicy: Never` |
| `05-global-default.yaml` | `globalDefault: true` |
| `06-second-default-BAD.yaml` | rejected -- only one default allowed |
| `07-custom-scheduler-pod.yaml` | `schedulerName: my-scheduler` |
| `08-scheduler-rbac.yaml` | ServiceAccount + bindings for a second scheduler |
| `09-my-scheduler.yaml` | ConfigMap + Deployment running kube-scheduler |
| `10-scheduler-profiles.yaml` | reference: five profiles in one binary |
| `verify.sh` | checks every claim in Part 4 |

> **Version note:** `09-my-scheduler.yaml` pins
> `registry.k8s.io/kube-scheduler:v1.31.4` to match this repo's kind cluster.
> On a different cluster, change it -- `kubectl version` tells you what to use.
> A scheduler more than one minor version off the API server is outside the
> supported skew (see [CKA 12](../../12-cluster-maintenance/)) and may fail on
> configuration API changes.

> **Do not `kubectl apply -f solution/`.** This directory contains
> `06-second-default-BAD.yaml`, which is meant to be rejected, and
> `10-scheduler-profiles.yaml`, which is a scheduler config file rather than
> something the API server accepts. Apply the files individually as the lab
> instructs.
