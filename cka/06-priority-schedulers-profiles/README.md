# CKA 06 — Priority Classes, Multiple Schedulers and Scheduler Profiles

**Time:** 75-90 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [CKA 05](../05-manual-scheduling-and-static-pods/), [Day 16](../../days/day-16-resources-requests-limits-metrics-server/)
**Source lectures:** 75, 77, 79, 80

CKA 01 said the scheduler filters then scores. CKA 05 showed you how to bypass
it. This assignment opens the scheduler up: how pods are **ordered** before
filtering even begins, what happens when a high-priority pod arrives at a full
cluster, and how to change the algorithm itself.

---

## Part 1 - Concepts

### 6.1 There is a queue before the filter

The full pipeline, which CKA 01 only showed the middle of:

```
    [ SCHEDULING QUEUE ]  pods sorted by PRIORITY      <- new here
              |
    [ FILTER ]            drop nodes that cannot work
              |
    [ SCORE ]             rank the survivors 0-10
              |
    [ BIND ]              write spec.nodeName
```

**Priority decides who gets looked at first.** When ten pods are pending and
capacity frees up, the queue order determines who wins the race — before any
node is even considered.

### 6.2 PriorityClass

A **cluster-scoped** object (no namespace) that names a number:

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority     # or Never
description: "Critical business workloads"
```

Attach it by name:

```yaml
spec:
  priorityClassName: high-priority
```

The number ranges that matter:

| Range | For |
|---|---|
| **-2,147,483,648 to 1,000,000,000** | your workloads |
| **above 1,000,000,000** | reserved for system-critical components |

Two built-ins exist already:

```bash
kubectl get priorityclass
```

```
NAME                      VALUE        GLOBAL-DEFAULT
system-cluster-critical   2000000000   false
system-node-critical      2000001000   false
```

`system-node-critical` is what keeps `kube-proxy` and the CNI alive when a node
is under pressure. **Never assign these to application pods.**

**Defaults:** a pod with no `priorityClassName` gets priority **0**. To change
that, set `globalDefault: true` on one class — and **only one**, since two
defaults is a contradiction the API rejects.

### 6.3 Preemption — the part with consequences

A high-priority pod arrives. The cluster is full. Now what?

That is decided by **`preemptionPolicy` on the incoming pod's class**:

| Policy | Behaviour |
|---|---|
| **`PreemptLowerPriority`** (default) | **evict** lower-priority pods to make room |
| **`Never`** | wait in the queue — but ahead of everything lower-priority |

> **The default is to evict.** A pod with a high priority class and no explicit
> `preemptionPolicy` will terminate other people's running workloads to schedule
> itself. That is usually what you want for a database and rarely what you want
> for a batch job.

Preemption is not arbitrary. The scheduler picks the **fewest, lowest-priority**
victims that free enough room, respects PodDisruptionBudgets on a best-effort
basis, and gives victims their normal `terminationGracePeriodSeconds`.

**Priority still applies with `Never`** — such a pod jumps the queue, it just
will not push anyone out to get there.

### 6.4 Multiple schedulers

The default scheduler covers most needs. When it genuinely cannot — you need
placement logic based on GPU topology, licence counts, or data locality — you
can run **another scheduler alongside it**.

Pods choose:

```yaml
spec:
  schedulerName: my-scheduler
```

**A pod naming a scheduler that is not running stays `Pending` forever, with no
events** — exactly like CKA 05's no-scheduler state, and for the same reason:
nothing is watching for it.

Two `kube-scheduler` settings matter here:

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: my-scheduler
leaderElection:
  leaderElect: false        # true only if you run several COPIES for HA
```

**`leaderElect`** is about redundancy, not about multiple schedulers: with
several copies of the *same* scheduler on different control-plane nodes, only
one is active and the rest stand by. For a single extra scheduler, set it
`false` — leaving it `true` with one replica just adds a lease and a delay.

### 6.5 Scheduler profiles — the better answer since 1.18

Running separate scheduler *binaries* has two real problems:

1. more processes to deploy, monitor and upgrade
2. **race conditions** — two schedulers can independently place pods on the same
   node, each unaware of the other's decision, and overcommit it

Since Kubernetes **1.18**, one scheduler binary can host **multiple profiles**,
each acting as a separate scheduler by name — sharing one process, one cache and
one view of the cluster:

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler

  - schedulerName: no-taints-scheduler
    plugins:
      filter:
        disabled:
          - name: TaintToleration

  - schedulerName: no-scoring-scheduler
    plugins:
      preScore:
        disabled:
          - name: '*'
      score:
        disabled:
          - name: '*'
```

**This is the modern answer**, and the one to give in an interview: multiple
profiles in one binary, not multiple binaries.

### 6.6 Plugins and extension points

Every stage of the pipeline is a set of **plugins** bound to an **extension
point**. That is what makes the scheduler configurable at all.

| Extension point | Plugins you have already met |
|---|---|
| `queueSort` | **PrioritySort** — implements 6.1 |
| `preFilter` / `filter` | **NodeResourcesFit** (requests), **TaintToleration** (Day 18), **NodeName** (CKA 05), **NodeUnschedulable** (`cordon`), **NodeAffinity** |
| `postFilter` | **DefaultPreemption** — implements 6.3 |
| `preScore` / `score` | **NodeResourcesFit**, **ImageLocality**, **PodTopologySpread**, **InterPodAffinity** |
| `reserve`, `permit`, `preBind` | extension hooks for custom logic |
| `bind` | **DefaultBinder** — writes the Binding from CKA 05 |

Two observations worth carrying:

- **One plugin can sit at several points.** `NodeResourcesFit` both filters
  (does it fit at all?) and scores (how much room is left?).
- **Score plugins never reject a node.** `ImageLocality` prefers nodes that
  already cached the image, but will happily place a pod on one that has not.
  Rejection only happens in `filter`.

Everything in Day 18 — taints, affinity, topology spread — is a plugin at one of
these points. Now you know where.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka06 2>/dev/null
kubectl config set-context --current --namespace=cka06
```

### Step 1: The built-in priority classes

```bash
kubectl get priorityclass
kubectl describe priorityclass system-node-critical
```

Now see one in use — this is what keeps the cluster alive under pressure:

```bash
kubectl get pods -n kube-system -o custom-columns=\
NAME:.metadata.name,PRIORITY:.spec.priority,CLASS:.spec.priorityClassName | head -12
```

`kube-proxy` and the CNI carry `system-node-critical` (2000001000); the
control-plane static pods carry `system-cluster-critical`. **Your pods are at 0
by default**, which is exactly why they are the first to be evicted.

### Step 2: Create priority classes

```bash
kubectl apply -f solution/01-priority-classes.yaml
kubectl get priorityclass
```

Note there is **no namespace** on any of them — they are cluster-scoped, so one
set serves every team.

```bash
kubectl get priorityclass low-priority -o jsonpath='{.metadata.namespace}{"\n"}'   # empty
```

### Step 3: Watch preemption happen

This is the demonstration worth doing carefully.

First, fill a node with low-priority pods:

```bash
kubectl apply -f solution/02-low-priority-filler.yaml
kubectl rollout status deployment/filler -n cka06 --timeout=120s
kubectl get pods -n cka06 -o wide
```

Check how full the node is:

```bash
NODE=$(kubectl get pods -n cka06 -l app=filler -o jsonpath='{.items[0].spec.nodeName}')
kubectl describe node "$NODE" | grep -A6 "Allocated resources"
```

Now schedule something that cannot fit, at higher priority:

```bash
kubectl get pods -n cka06 -w &
WATCH=$!
kubectl apply -f solution/03-high-priority-pod.yaml
sleep 25
kill $WATCH 2>/dev/null

kubectl get pods -n cka06
kubectl get events -n cka06 --sort-by=.lastTimestamp | grep -i -E "preempt|evict" | tail -5
```

```
Normal   Preempted   pod/filler-xxx   Preempted by cka06/important-app on node devops-worker
Normal   Scheduled   pod/important-app  Successfully assigned ...
```

**A running pod was terminated to make room.** The Deployment then recreates the
victim, which goes Pending because there is still no space — priority did not
create capacity, it just decided who gets it.

### Step 4: The same thing with `preemptionPolicy: Never`

```bash
kubectl delete -f solution/03-high-priority-pod.yaml
sleep 10
kubectl apply -f solution/04-high-priority-nopreempt.yaml
sleep 20

kubectl get pods -n cka06 | grep patient
kubectl describe pod patient-app -n cka06 | grep -A4 Events
```

```
Warning  FailedScheduling  0/3 nodes are available: 3 Insufficient cpu.
```

**Pending, and nothing was evicted.** It still outranks every low-priority pod
in the queue — the moment capacity frees it goes first — but it will not take
capacity by force.

```bash
kubectl delete -f solution/04-high-priority-nopreempt.yaml
kubectl delete -f solution/02-low-priority-filler.yaml
```

### Step 5: A global default

```bash
kubectl apply -f solution/05-global-default.yaml
kubectl get priorityclass | grep -i true

kubectl run defaulted -n cka06 --image=nginx:alpine
sleep 5
kubectl get pod defaulted -n cka06 -o jsonpath='{.spec.priority}{"  class="}{.spec.priorityClassName}{"\n"}'
```

The pod declared nothing yet has a priority — injected at admission, exactly
like a LimitRange injects resources (Day 03).

Now prove only one default may exist:

```bash
kubectl apply -f solution/06-second-default-BAD.yaml
```

```
Error ... PriorityClass "another-default" is forbidden:
there is already a PriorityClass with globalDefault=true
```

```bash
kubectl delete pod defaulted -n cka06
kubectl delete -f solution/05-global-default.yaml
```

### Step 6: A pod that names a scheduler which does not exist

```bash
kubectl apply -f solution/07-custom-scheduler-pod.yaml
sleep 12
kubectl get pod uses-custom-scheduler -n cka06
kubectl describe pod uses-custom-scheduler -n cka06 | grep -A3 Events
```

`Pending`, **no events at all** — the CKA 05 signature. No scheduler answers to
`my-scheduler`, so nothing has looked at this pod. Confirm the difference:

```bash
kubectl get pod uses-custom-scheduler -n cka06 -o jsonpath='{.spec.schedulerName}{"\n"}'
```

**Diagnostic rule:** `Pending` + `FailedScheduling` events = a scheduler
considered it and refused. `Pending` + *no* events = no scheduler is watching —
either none is running, or `schedulerName` names one that does not exist.

### Step 7: Deploy a second scheduler

```bash
kubectl apply -f solution/08-scheduler-rbac.yaml
kubectl apply -f solution/09-my-scheduler.yaml
kubectl rollout status deployment/my-scheduler -n kube-system --timeout=180s
kubectl get pods -n kube-system -l app=my-scheduler
```

Now the pod from Step 6 gets picked up:

```bash
sleep 20
kubectl get pod uses-custom-scheduler -n cka06 -o wide
kubectl get events -n cka06 --field-selector involvedObject.name=uses-custom-scheduler
```

```
Normal  Scheduled  my-scheduler  Successfully assigned cka06/uses-custom-scheduler to devops-worker
```

**Read the `From` column: `my-scheduler`, not `default-scheduler`.** That is the
proof — a different process made this decision.

```bash
kubectl logs -n kube-system -l app=my-scheduler --tail=15
```

### Step 8: Inspect the default scheduler's own configuration

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'config|authentication' /etc/kubernetes/manifests/kube-scheduler.yaml"
docker exec devops-control-plane cat /etc/kubernetes/scheduler.conf 2>/dev/null | head -5
```

kind runs the default scheduler with no explicit profile file — the built-in
defaults. `solution/10-scheduler-profiles.yaml` shows what a multi-profile
configuration looks like, with comments on where each plugin sits.

```bash
cat solution/10-scheduler-profiles.yaml
```

Read it against the extension-point table in 6.6.

---

## Part 3 - Challenges

Do these without looking at `solution/`.

### C1 - Rank a real cluster

Three workloads share a cluster with 6 CPU total:
- `payments` — must never be evicted, may evict others
- `reporting` — should run before batch work but must never terminate anything
- `nightly-etl` — lowest, first to go

Write three PriorityClasses and the `priorityClassName` line for each workload.
State which value you gave `reporting` and why it is above 0.

### C2 - Preemption forensics

A colleague says "my pod just vanished". Using only `kubectl`, determine:
1. Was it preempted, or OOMKilled, or evicted for node pressure?
2. If preempted — by which pod, on which node?

Write the exact commands. (Hint: three different sources — pod events, the
Deployment's replica events, and `kubectl get events` on the *victim's*
namespace.)

### C3 - Choose the architecture

You need pods with GPUs placed by topology-aware logic. Argue for **scheduler
profiles** over a **second scheduler binary** in four sentences, naming the
specific failure mode that separate binaries introduce.

Then say when the answer flips — when a second binary genuinely is required.

### C4 - Break and diagnose

Create a pod that stays `Pending` **with no events**, and a second pod that
stays `Pending` **with a `FailedScheduling` event**. Explain what distinguishes
the two states and which one indicates a *cluster* problem versus a *pod* problem.

### C5 - Read the profile

Given this fragment, predict the behaviour and name what breaks:

```yaml
profiles:
  - schedulerName: fast-scheduler
    plugins:
      filter:
        disabled:
          - name: NodeResourcesFit
```

What now happens to a pod requesting 32 CPU on a 4-CPU cluster?

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: priority classes exist with correct values; a preemption event was
recorded; the `Never` policy pod stayed Pending without evicting; the second
scheduler is Running and bound at least one pod.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# create a priority class imperatively -- there is no `kubectl create priorityclass`
kubectl create -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: high}
value: 1000000
EOF

# which class does a pod use, and what number did it resolve to
kubectl get pod X -o jsonpath='{.spec.priorityClassName} {.spec.priority}{"\n"}'

# every pod's priority, sorted -- who dies first
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PRI:.spec.priority \
  --sort-by=.spec.priority

# preemption evidence
kubectl get events -A --field-selector reason=Preempted

# which scheduler placed this pod
kubectl get events --field-selector involvedObject.name=X -o custom-columns=FROM:.source.component,MSG:.message
```

**Traps**

- **PriorityClass is cluster-scoped.** `-n` on the create is ignored; `kubectl get pc` without `-A` already shows everything.
- **`spec.priority` is immutable.** Changing a PriorityClass's `value` does **not** update pods already admitted — the number was resolved and stamped at admission. Existing pods keep the old priority until recreated.
- **`preemptionPolicy` defaults to evicting.** If the task says "must not disrupt running workloads", you must set `Never` explicitly.
- **Only one `globalDefault: true`.** A second is rejected by the API.
- **Values above 1,000,000,000** are for system components. Do not use them on app pods; you will starve `kube-proxy` and break the node.
- **`schedulerName` is a pod-spec field**, so it is immutable too — you cannot move an existing pod to a different scheduler; recreate it.
- **A missing scheduler gives no events**, not an error. Silence is the symptom.
- **Multiple profiles > multiple binaries** (1.18+). Say this if asked.
- Short name for PriorityClass is **`pc`**.

**Cleanup**

```bash
kubectl delete -f solution/09-my-scheduler.yaml --ignore-not-found
kubectl delete -f solution/08-scheduler-rbac.yaml --ignore-not-found
kubectl delete namespace cka06 --ignore-not-found
kubectl delete priorityclass low-priority high-priority patient-priority --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

**Previous:** [CKA 05 — Manual Scheduling and Static Pods](../05-manual-scheduling-and-static-pods/)
**Next: CKA 07 — Admission Controllers** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
